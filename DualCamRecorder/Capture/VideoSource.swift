//
//  VideoSource.swift
//  DualCamRecorder
//

import Foundation
import CoreMedia
import CoreVideo

/// Detected input format, independent of the source implementation.
struct VideoFormatInfo: Equatable {
    var modeName: String
    var width: Int
    var height: Int
    var frameDuration: CMTime
    var interlaced: Bool
    var rgb444: Bool
    var bitDepth: Int
    var pixelFormat: OSType

    var frameRate: Double {
        frameDuration.seconds > 0 ? 1.0 / frameDuration.seconds : 0
    }

    var displayString: String {
        let fps = frameRate
        let fpsString = abs(fps - fps.rounded()) < 0.001 ? String(format: "%.0f", fps) : String(format: "%.3f", fps)
        let scan = interlaced ? "i" : "p"
        var parts = ["\(width)×\(height)\(scan)\(fpsString)"]
        parts.append(rgb444 ? "RGB 4:4:4" : "YUV 4:2:2")
        if bitDepth > 0 { parts.append("\(bitDepth)-bit") }
        parts.append("[\(modeName)]")
        return parts.joined(separator: " · ")
    }
}

struct CapturedAudio {
    /// Interleaved Int32 PCM @ 48 kHz.
    var data: Data
    var sampleFrames: Int
    var channels: Int
    /// Packet time in 48 kHz units on the same stream timeline as `CapturedFrame.streamTime`.
    var packetTime: Int64
}

/// One frame delivered by a source. `pixelBuffer` is owned by the frame (already copied from the device).
struct CapturedFrame {
    var pixelBuffer: CVPixelBuffer
    var streamTime: CMTime
    var duration: CMTime
    /// Capture time on the shared host clock (ns) – comparable between sources.
    var hostTimeNanos: UInt64
    var hasSignal: Bool
    /// Frames lost by the input before this one.
    var droppedBefore: Int
    var audio: CapturedAudio?
    /// Timecode the camera embeds in the signal (nil: none).
    var timecode: Timecode? = nil
    var timecodeUserBits: UInt32 = 0
    /// Camera's record trigger from the signal (nil: the camera does not send one).
    var cameraRecording: Bool? = nil
    /// All ancillary packets – only while the SDI data log runs.
    var ancillary: [AncillaryPacket]? = nil
}

protocol VideoSourceDelegate: AnyObject {
    /// Called on a capture thread. Must return fast.
    func videoSource(_ source: VideoSource, didCapture frame: CapturedFrame)
    /// Called on the main queue.
    func videoSource(_ source: VideoSource, didDetectFormat format: VideoFormatInfo)
    /// Called on the main queue.
    func videoSource(_ source: VideoSource, didFail message: String)
}

protocol VideoSource: AnyObject {
    var delegate: VideoSourceDelegate? { get set }
    var displayName: String { get }
    /// Deliver the ancillary packets of every frame (SDI data log).
    var captureAncillary: Bool { get set }
    func start() throws
    func stop()
}
