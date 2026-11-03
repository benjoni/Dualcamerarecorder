//
//  Timecode.swift
//  DualCamRecorder
//
//  SMPTE timecode sent by the camera in the SDI signal (RP188 / VITC), the camera's own REC state
//  (record flag in the timecode user bits, or rec-run timecode) and the raw ancillary data for the SDI log.
//

import Foundation

struct Timecode: Codable, Hashable {
    var hours = 0
    var minutes = 0
    var seconds = 0
    var frames = 0
    /// 29.97 / 59.94 drop-frame counting (written with ";" before the frames).
    var dropFrame = false

    /// "14:32:07:12" ("14:32:07;12" for drop-frame).
    var string: String {
        String(format: "%02d:%02d:%02d%@%02d", hours, minutes, seconds, dropFrame ? ";" : ":", frames)
    }

    /// Timecode counting base of a frame duration: 24 for 23.976, 30 for 29.97, 25, 50, 60 …
    static func base(frameDuration seconds: Double) -> Int {
        guard seconds > 0 else { return 25 }
        return max(1, Int((1.0 / seconds).rounded()))
    }

    /// Frames since 00:00:00:00 (drop-frame aware).
    func frameNumber(base: Int) -> Int {
        let total = ((hours * 60 + minutes) * 60 + seconds) * base + frames
        guard dropFrame, base == 30 || base == 60 else { return total }
        let drop = base / 15                    // 2 frames (29.97) or 4 (59.94) every minute except each 10th
        let totalMinutes = hours * 60 + minutes
        return total - drop * (totalMinutes - totalMinutes / 10)
    }

    init(hours: Int = 0, minutes: Int = 0, seconds: Int = 0, frames: Int = 0, dropFrame: Bool = false) {
        self.hours = hours
        self.minutes = minutes
        self.seconds = seconds
        self.frames = frames
        self.dropFrame = dropFrame
    }

    /// Timecode of a frame number (wraps at 24 h).
    init(frameNumber: Int, base: Int, dropFrame: Bool = false) {
        let base = max(1, base)
        let day = 24 * 3600 * base
        var n = ((frameNumber % day) + day) % day
        let dropping = dropFrame && (base == 30 || base == 60)
        if dropping {
            let drop = base / 15
            let perMinute = base * 60 - drop
            let perTenMinutes = base * 600 - drop * 9
            let tens = n / perTenMinutes
            let rest = n % perTenMinutes
            n += drop * 9 * tens + (rest > drop ? drop * ((rest - drop) / perMinute) : 0)
        }
        frames = n % base
        seconds = (n / base) % 60
        minutes = (n / (base * 60)) % 60
        hours = n / (base * 3600)
        self.dropFrame = dropping
    }

    /// "14:32:07:12" or "14:32:07;12".
    init?(string: String) {
        let parts = string.split(whereSeparator: { $0 == ":" || $0 == ";" || $0 == "." }).compactMap { Int($0) }
        guard parts.count == 4 else { return nil }
        self.init(hours: parts[0], minutes: parts[1], seconds: parts[2], frames: parts[3], dropFrame: string.contains(";"))
    }

    func adding(frames count: Int, base: Int) -> Timecode {
        Timecode(frameNumber: frameNumber(base: base) + count, base: base, dropFrame: dropFrame)
    }
}

/// TC IN / TC OUT of one recorded file (OUT = timecode of the last frame).
struct TimecodeRange: Codable, Hashable {
    var start: Timecode
    var end: Timecode
    var base: Int

    var label: String { "TC \(start.string) – \(end.string)" }

    /// Source timecode at `seconds` into the file.
    func at(seconds: Double, frameDuration: Double) -> Timecode {
        let frames = frameDuration > 0 ? Int((seconds / frameDuration).rounded(.down)) : 0
        return start.adding(frames: frames, base: base)
    }
}

/// Whether the camera itself is recording (from the SDI signal).
enum CameraRecState: Equatable {
    case unknown, recording, stopped
}

/// How the camera's REC is read from its SDI signal (per input, per project).
enum CameraRecDetection: String, Codable, CaseIterable, Identifiable {
    /// Record flag sent by the camera (Blackmagic RP188 user-bit trigger and similar).
    case flag
    /// Flag, or else the timecode: running = recording, standing = stopped (camera set to Rec Run timecode).
    case recRun
    /// Blackmagic cameras (Pyxis, URSA, Pocket …): REC is bit 0x08 of the timecode user bits.
    case userBits
    case off
    var id: String { rawValue }
    var title: String {
        switch self {
        case .flag: return "SDI record flag"
        case .recRun: return "Flag or Rec Run timecode"
        case .userBits: return "Blackmagic (REC in timecode user bits)"
        case .off: return "Off"
        }
    }

    /// Blackmagic REC bit in the timecode user bits.
    static let userBitsRec: UInt32 = 0x08
}

/// Start / stop recording in the app together with the camera (per project).
enum CameraTrigger: String, Codable, CaseIterable, Identifiable {
    case off, a, b, any
    var id: String { rawValue }
}

/// One ancillary data packet of a frame (SDI log only).
struct AncillaryPacket: Equatable {
    var did: UInt8
    var sdid: UInt8
    var line: UInt32
    var stream: UInt8
    var data: Data
}
