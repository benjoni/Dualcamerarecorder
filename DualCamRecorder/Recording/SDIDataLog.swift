//
//  SDIDataLog.swift
//  DualCamRecorder
//
//  Diagnostic log of what a camera sends in the SDI signal besides the picture: timecode, its user bits and
//  record flag, and every ancillary (VANC) packet – written only when something changes, so pressing REC / STOP
//  on the camera shows which packet carries the camera's own record state.
//

import Foundation

final class SDIDataLog {
    private let handle: FileHandle
    private let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    private var frames = 0
    private var lastPackets: [String: Data] = [:]
    /// Frames in a row a packet changed – packets changing on every frame (timecode) are logged once a second.
    private var streak: [String: Int] = [:]
    private var lastTrigger: Bool??
    private var lastUserBits: UInt32?
    private var lastHadTimecode: Bool?
    private var lastHadPackets: Bool?

    init?(url: URL, camera: String) {
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else { return nil }
        self.handle = handle
        write("""
        DualCamRecorder – SDI data log, camera \(camera), started \(Date())
        Lines are written only when something changes. To find the camera's record flag: wait a few seconds,
        press REC on the camera, wait, press STOP, wait – then look for packets that change at those moments.
        ANC = ancillary packet: DID / SDID (hex), line, data stream, length, data (hex). TC = camera timecode.

        """)
    }

    deinit { try? handle.close() }

    func close() {
        note("Log stopped")
        try? handle.close()
    }

    func note(_ text: String) {
        write("\(clock.string(from: Date()))  -- \(text)\n")
    }

    func add(_ frame: CapturedFrame) {
        frames += 1
        let time = clock.string(from: Date())
        let tc = frame.timecode?.string ?? "--:--:--:--"
        var lines: [String] = []

        if lastHadTimecode != (frame.timecode != nil) {
            lastHadTimecode = frame.timecode != nil
            lines.append(frame.timecode != nil ? "timecode present" : "NO timecode in the signal")
        }
        if lastTrigger != .some(frame.cameraRecording) {
            lastTrigger = .some(frame.cameraRecording)
            lines.append("record flag: " + (frame.cameraRecording.map { $0 ? "RECORDING" : "stopped" } ?? "not sent"))
        }
        if frame.timecode != nil, lastUserBits != frame.timecodeUserBits {
            let key = "userbits"
            streak[key, default: 0] += 1
            if streak[key, default: 0] < 25 || frames % 25 == 0 {
                lines.append(String(format: "user bits %08X", frame.timecodeUserBits) + (streak[key, default: 0] >= 25 ? "  (changes every frame)" : ""))
            }
            lastUserBits = frame.timecodeUserBits
        } else {
            streak["userbits"] = 0
        }

        if let packets = frame.ancillary {
            if lastHadPackets != !packets.isEmpty {
                lastHadPackets = !packets.isEmpty
                lines.append(packets.isEmpty ? "no ancillary packets" : "\(packets.count) ancillary packets per frame")
            }
            var seen = Set<String>()
            for p in packets {
                let key = String(format: "%02X/%02X/%d/%d", p.did, p.sdid, p.line, p.stream)
                seen.insert(key)
                if lastPackets[key] == p.data { streak[key] = 0; continue }
                let isNew = lastPackets[key] == nil
                lastPackets[key] = p.data
                streak[key, default: 0] += 1
                let everyFrame = streak[key, default: 0] >= 25
                if everyFrame && frames % 25 != 0 { continue }
                let hex = p.data.map { String(format: "%02X", $0) }.joined(separator: " ")
                lines.append(String(format: "ANC %@ DID %02X SDID %02X line %d stream %d len %d: ", isNew ? "new" : "chg",
                                    p.did, p.sdid, p.line, p.stream, p.data.count) + hex + (everyFrame ? "  (changes every frame)" : ""))
            }
            for key in lastPackets.keys where !seen.contains(key) {
                lastPackets[key] = nil
                streak[key] = nil
                lines.append("ANC gone \(key)")
            }
        }
        guard !lines.isEmpty else { return }
        write(lines.map { "\(time)  TC \(tc)  \($0)\n" }.joined())
    }

    private func write(_ text: String) {
        if let data = text.data(using: .utf8) { try? handle.write(contentsOf: data) }
    }
}
