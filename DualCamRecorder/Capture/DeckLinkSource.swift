//
//  DeckLinkSource.swift
//  DualCamRecorder
//

import Foundation
import CoreMedia

/// `VideoSource` backed by a Blackmagic device through the Objective-C++ bridge.
final class DeckLinkSource: NSObject, VideoSource, DLCaptureDeviceDelegate {
    weak var delegate: VideoSourceDelegate?
    let displayName: String
    private let device: DLCaptureDevice

    init?(descriptor: DLDeviceDescriptor, audioChannels: Int, forceEightBit: Bool) {
        guard let device = DLCaptureDevice(identifier: descriptor.identifier) else { return nil }
        self.device = device
        self.displayName = descriptor.displayName
        super.init()
        device.audioChannels = Int32(audioChannels)
        device.forceEightBit = forceEightBit
        device.forceSDIInput = true
        device.delegate = self
    }

    func start() throws {
        try device.start()
    }

    func stop() {
        device.stop()
    }

    var captureAncillary: Bool {
        get { device.captureAncillary }
        set { device.captureAncillary = newValue }
    }

    // MARK: DLCaptureDeviceDelegate

    func captureDevice(_ device: DLCaptureDevice, didCaptureFrame frame: DLCaptureFrame) {
        var audio: CapturedAudio?
        if let data = frame.audioData, frame.audioSampleFrames > 0 {
            audio = CapturedAudio(data: data,
                                  sampleFrames: Int(frame.audioSampleFrames),
                                  channels: Int(frame.audioChannels),
                                  packetTime: frame.audioPacketTime)
        }
        let timeScale = CMTimeScale(clamping: frame.timeScale)
        var captured = CapturedFrame(pixelBuffer: frame.pixelBuffer,
                                     streamTime: CMTime(value: frame.streamTime, timescale: timeScale),
                                     duration: CMTime(value: frame.frameDuration, timescale: timeScale),
                                     hostTimeNanos: frame.hostTimeNanos,
                                     hasSignal: frame.hasSignal,
                                     droppedBefore: Int(frame.droppedBefore),
                                     audio: audio)
        if frame.hasTimecode {
            captured.timecode = Timecode(hours: Int(frame.tcHours), minutes: Int(frame.tcMinutes), seconds: Int(frame.tcSeconds),
                                         frames: Int(frame.tcFrames), dropFrame: frame.tcDropFrame)
            captured.timecodeUserBits = frame.tcUserBits
        }
        if frame.recordTrigger >= 0 { captured.cameraRecording = frame.recordTrigger == 1 }
        captured.ancillary = frame.ancillaryPackets?.map {
            AncillaryPacket(did: $0.did, sdid: $0.sdid, line: $0.lineNumber, stream: $0.dataStreamIndex, data: $0.data)
        }
        delegate?.videoSource(self, didCapture: captured)
    }

    func captureDevice(_ device: DLCaptureDevice, didDetectFormat format: DLFormatInfo) {
        let info = VideoFormatInfo(modeName: format.modeName,
                                   width: Int(format.width),
                                   height: Int(format.height),
                                   frameDuration: CMTime(value: format.frameDuration,
                                                         timescale: CMTimeScale(clamping: format.timeScale)),
                                   interlaced: format.interlaced,
                                   rgb444: format.rgb444,
                                   bitDepth: Int(format.bitDepth),
                                   pixelFormat: format.pixelFormat)
        delegate?.videoSource(self, didDetectFormat: info)
    }

    func captureDevice(_ device: DLCaptureDevice, didFailWithMessage message: String) {
        delegate?.videoSource(self, didFail: message)
    }
}
