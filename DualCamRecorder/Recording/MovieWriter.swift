//
//  MovieWriter.swift
//  DualCamRecorder
//
//  AVAssetWriter wrapper: ProRes 422 or H.265 (.mov) video + uncompressed 24-bit LPCM audio (SDI and/or audio interface).
//  Not thread-safe: use from one serial queue (CameraChannel.queue).
//

import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import VideoToolbox
import os

enum ProResFlavor: String, CaseIterable, Identifiable {
    case proRes422 = "422"
    case proRes422HQ = "422HQ"
    case proRes422LT = "422LT"
    /// H.265 / HEVC (8-bit Main) from the Mac's hardware encoder – about a third of ProRes LT on disk.
    case hevc = "HEVC"

    var id: String { rawValue }

    var codec: AVVideoCodecType {
        switch self {
        case .proRes422: return .proRes422
        case .proRes422HQ: return .proRes422HQ
        case .proRes422LT: return .proRes422LT
        case .hevc: return .hevc
        }
    }

    var title: String {
        switch self {
        case .proRes422: return "ProRes 422"
        case .proRes422HQ: return "ProRes 422 HQ"
        case .proRes422LT: return "ProRes 422 LT"
        case .hevc: return "H.265 (HEVC)"
        }
    }

    /// H.265 data rates to choose from (Mbit/s for 1920×1080, scaled with the picture size); 5 is the default.
    static let hevcRates = [5, 10, 20, 45]
    static let defaultHEVCRate = 5

    /// Approximate video bits per second for 1920×1080 at `fps` (Apple ProRes white paper, 29.97p data
    /// rates; H.265 at its chosen data rate, whatever the frame rate).
    func approxBitsPerSecondHD(fps: Double, hevcMbps: Int) -> Double {
        switch self {
        case .proRes422: return 147_000_000 / 29.97 * fps
        case .proRes422HQ: return 220_000_000 / 29.97 * fps
        case .proRes422LT: return 102_000_000 / 29.97 * fps
        case .hevc: return Double(hevcMbps) * 1_000_000
        }
    }

    /// Encoder settings beyond the codec (H.265: data rate, 8-bit Main profile, a key frame every second, no B-frames –
    /// for real-time encoding and frame-accurate cutting).
    func compressionProperties(width: Int, height: Int, hevcMbps: Int) -> [String: Any]? {
        guard self == .hevc else { return nil }
        let bitRate = Double(hevcMbps) * 1_000_000 * Double(width * height) / (1920 * 1080)
        return [
            AVVideoAverageBitRateKey: Int(bitRate),
            AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String,
            AVVideoMaxKeyFrameIntervalDurationKey: 1.0,
            AVVideoAllowFrameReorderingKey: false,
            kVTCompressionPropertyKey_RealTime as String: true,
        ]
    }
}

/// The first H.265 encoder of the app takes over a second to start (hardware encoder loading) – frames of
/// the first take were lost. One blank frame is encoded in the background as soon as H.265 is chosen.
enum HEVCWarmup {
    private static let done = OSAllocatedUnfairLock(initialState: false)

    static func run() {
        guard done.withLock({ d -> Bool in defer { d = true }; return !d }) else { return }
        DispatchQueue.global(qos: .utility).async {
            var session: VTCompressionSession?
            guard VTCompressionSessionCreate(allocator: nil, width: 1920, height: 1080, codecType: kCMVideoCodecType_HEVC,
                                             encoderSpecification: nil, imageBufferAttributes: nil,
                                             compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                                             compressionSessionOut: &session) == noErr, let session else { return }
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
            VTCompressionSessionPrepareToEncodeFrames(session)
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_422YpCbCr8, nil, &buffer)
            if let buffer {
                VTCompressionSessionEncodeFrame(session, imageBuffer: buffer, presentationTimeStamp: .zero,
                                                duration: .invalid, frameProperties: nil, infoFlagsOut: nil) { _, _, _ in }
                VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            }
            VTCompressionSessionInvalidate(session)
        }
    }
}

enum MovieWriterError: LocalizedError {
    case cannotCreate(String)
    case cannotAddInput(String)
    case cannotStart(String)

    var errorDescription: String? {
        switch self {
        case .cannotCreate(let s): return "Cannot create file: \(s)"
        case .cannotAddInput(let s): return "AVAssetWriter rejected input: \(s)"
        case .cannotStart(let s): return "Writing did not start: \(s)"
        }
    }
}

final class MovieWriter {
    let url: URL
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioInput: AVAssetWriterInput?
    /// QuickTime timecode track (camera timecode), nil when the camera sends none.
    private let timecodeInput: AVAssetWriterInput?
    private let timecodeFormat: CMTimeCodeFormatDescription?
    private let audioChannels: Int
    private var audioFormat: CMAudioFormatDescription?
    /// Audio interface track (nil when the project does not use one).
    private let interfaceInput: AVAssetWriterInput?
    private let interfaceFormat: CMAudioFormatDescription?
    let interfaceChannels: Int
    private(set) var videoFramesWritten = 0
    private(set) var audioSamplesWritten = 0
    private(set) var interfaceSamplesWritten = 0
    private var sessionStarted = false

    /// Camera timecode of a take: the file gets a timecode track (frame duration, counting base, drop-frame).
    struct TimecodeTrack {
        var frameDuration: CMTime
        var base: Int
        var dropFrame: Bool
    }

    /// 24-bit LPCM 48 kHz track for `channels` interleaved Int32 channels (stereo layout for 2, discrete otherwise).
    private static func makeAudioTrack(channels: Int, writer: AVAssetWriter, name: String,
                                       enabled: Bool = true) throws -> (input: AVAssetWriterInput, format: CMAudioFormatDescription?) {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channels == 2
            ? kAudioChannelLayoutTag_Stereo
            : (kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(channels))
        let layoutData = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVChannelLayoutKey: layoutData,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        input.marksOutputTrackAsEnabled = enabled
        guard writer.canAdd(input) else { throw MovieWriterError.cannotAddInput(name) }
        writer.add(input)

        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * channels),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                       formatDescriptionOut: &format)
        return (input, format)
    }

    /// `interfaceChannels` > 0 adds a track for the audio interface (Focusrite …) before the SDI audio track.
    init(url: URL, width: Int, height: Int, flavor: ProResFlavor, hevcMbps: Int = ProResFlavor.defaultHEVCRate, audioChannels: Int,
         interfaceChannels: Int = 0, metadata: [AVMetadataItem] = [], timecode: TimecodeTrack? = nil) throws {
        self.url = url
        self.audioChannels = audioChannels
        self.interfaceChannels = interfaceChannels
        if FileManager.default.fileExists(atPath: url.path) {
            throw MovieWriterError.cannotCreate("\(url.lastPathComponent) already exists")
        }
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        } catch {
            throw MovieWriterError.cannotCreate(error.localizedDescription)
        }
        writer.metadata = metadata
        // Fragments keep the file recoverable if the app/computer dies or the disk is pulled mid-take
        // (everything up to the last fragment can be played).
        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)

        var videoSettings: [String: Any] = [
            AVVideoCodecKey: flavor.codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        if let compression = flavor.compressionProperties(width: width, height: height, hevcMbps: hevcMbps) {
            videoSettings[AVVideoCompressionPropertiesKey] = compression
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(videoInput) else { throw MovieWriterError.cannotAddInput("video") }
        writer.add(videoInput)

        // Audio interface track first (the one players use), then the cameras' SDI sound – with the interface
        // the SDI track is kept for the edit but not played (two enabled tracks would be mixed).
        var interfaceInput: AVAssetWriterInput?
        var interfaceFormat: CMAudioFormatDescription?
        if interfaceChannels > 0 {
            let track = try Self.makeAudioTrack(channels: interfaceChannels, writer: writer, name: "audio interface")
            interfaceInput = track.input
            interfaceFormat = track.format
        }
        var audioInput: AVAssetWriterInput?
        var audioFormat: CMAudioFormatDescription?
        if audioChannels > 0 {
            let track = try Self.makeAudioTrack(channels: audioChannels, writer: writer, name: "audio",
                                                enabled: interfaceChannels == 0)
            audioInput = track.input
            audioFormat = track.format
        }

        // Timecode track tied to the video track – editors (Resolve, Premiere, Avid, FCP) read the source timecode.
        var timecodeInput: AVAssetWriterInput?
        var timecodeFormat: CMTimeCodeFormatDescription?
        if let timecode {
            var flags = kCMTimeCodeFlag_24HourMax
            if timecode.dropFrame { flags |= kCMTimeCodeFlag_DropFrame }
            var fd: CMTimeCodeFormatDescription?
            CMTimeCodeFormatDescriptionCreate(allocator: kCFAllocatorDefault, timeCodeFormatType: kCMTimeCodeFormatType_TimeCode32,
                                              frameDuration: timecode.frameDuration, frameQuanta: UInt32(timecode.base),
                                              flags: flags, extensions: nil, formatDescriptionOut: &fd)
            if let fd {
                let input = AVAssetWriterInput(mediaType: .timecode, outputSettings: nil, sourceFormatHint: fd)
                input.expectsMediaDataInRealTime = true
                let association = AVAssetTrack.AssociationType.timecode.rawValue
                if writer.canAdd(input) {
                    writer.add(input)
                    if videoInput.canAddTrackAssociation(withTrackOf: input, type: association) {
                        videoInput.addTrackAssociation(withTrackOf: input, type: association)
                    }
                    timecodeInput = input
                    timecodeFormat = fd
                }
            }
        }

        guard writer.startWriting() else {
            throw MovieWriterError.cannotStart(writer.error?.localizedDescription ?? "unknown error")
        }
        self.writer = writer
        self.videoInput = videoInput
        self.adaptor = adaptor
        self.audioInput = audioInput
        self.audioFormat = audioFormat
        self.interfaceInput = interfaceInput
        self.interfaceFormat = interfaceFormat
        self.timecodeInput = timecodeInput
        self.timecodeFormat = timecodeFormat
    }

    var hasTimecodeTrack: Bool { timecodeInput != nil }

    /// One timecode sample (frame number since 00:00:00:00) for the video frame at `pts`.
    @discardableResult
    func appendTimecode(frameNumber: Int, at pts: CMTime, duration: CMTime) -> Bool {
        guard sessionStarted, let timecodeInput, let timecodeFormat,
              writer.status == .writing, timecodeInput.isReadyForMoreMediaData else { return false }
        var value = Int32(truncatingIfNeeded: frameNumber).bigEndian
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: 4,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: 4, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr, let block,
              CMBlockBufferReplaceDataBytes(with: &value, blockBuffer: block, offsetIntoDestination: 0, dataLength: 4) == noErr
        else { return false }
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var size = 4
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true,
                                   makeDataReadyCallback: nil, refcon: nil, formatDescription: timecodeFormat,
                                   sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                   sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
              let sample else { return false }
        let ok = timecodeInput.append(sample)
        noteFailure(in: "timecode")
        return ok
    }

    var failed: Bool { writer.status == .failed }
    /// Track whose append made the writer fail first (video / audio / timecode).
    private(set) var failedTrack: String?

    private func noteFailure(in track: String) {
        guard failedTrack == nil, writer.status == .failed else { return }
        failedTrack = track
        NSLog("DualCamRecorder: writer failed in %@ track (%@): %@", track, url.lastPathComponent, String(describing: writer.error))
    }

    /// "Cannot Complete Action (audio, -11800 / -12737)" – the track and the underlying codes help find the cause.
    var errorDescription: String? {
        guard let error = writer.error as NSError? else { return nil }
        var codes = ["\(error.code)"]
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { codes.append("\(underlying.code)") }
        let track = failedTrack.map { "\($0), " } ?? ""
        return "\(error.localizedDescription) (\(track)\(codes.joined(separator: " / ")))"
    }

    /// Starts the timeline at zero. Call before the first append.
    func startSession() {
        guard !sessionStarted else { return }
        writer.startSession(atSourceTime: .zero)
        sessionStarted = true
    }

    /// Returns false if the frame had to be dropped (encoder not ready / writer failed).
    func appendVideo(_ pixelBuffer: CVPixelBuffer, at pts: CMTime) -> Bool {
        guard sessionStarted, writer.status == .writing, videoInput.isReadyForMoreMediaData else { return false }
        if adaptor.append(pixelBuffer, withPresentationTime: pts) {
            videoFramesWritten += 1
            return true
        }
        noteFailure(in: "video")
        return false
    }

    /// Appends `frames` interleaved Int32 sample frames starting at `offsetFrames` of `data` (SDI audio track).
    @discardableResult
    func appendAudio(_ data: Data, offsetFrames: Int, frames: Int, at pts: CMTime) -> Bool {
        guard let audioInput, let audioFormat else { return false }
        let ok = append(data, offsetFrames: offsetFrames, frames: frames, channels: audioChannels, at: pts,
                        to: audioInput, format: audioFormat, track: "audio")
        if ok { audioSamplesWritten += frames }
        return ok
    }

    /// Same for the audio interface track.
    @discardableResult
    func appendInterfaceAudio(_ data: Data, offsetFrames: Int, frames: Int, at pts: CMTime) -> Bool {
        guard let interfaceInput, let interfaceFormat else { return false }
        let ok = append(data, offsetFrames: offsetFrames, frames: frames, channels: interfaceChannels, at: pts,
                        to: interfaceInput, format: interfaceFormat, track: "audio interface")
        if ok { interfaceSamplesWritten += frames }
        return ok
    }

    private func append(_ data: Data, offsetFrames: Int, frames: Int, channels: Int, at pts: CMTime,
                        to input: AVAssetWriterInput, format: CMAudioFormatDescription, track: String) -> Bool {
        guard sessionStarted, frames > 0, writer.status == .writing, input.isReadyForMoreMediaData else { return false }
        let bytesPerFrame = 4 * channels
        let byteOffset = offsetFrames * bytesPerFrame
        let byteCount = frames * bytesPerFrame
        guard byteOffset + byteCount <= data.count else { return false }

        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                                        blockLength: byteCount, blockAllocator: kCFAllocatorDefault,
                                                        customBlockSource: nil, offsetToData: 0, dataLength: byteCount,
                                                        flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard status == noErr, let block else { return false }
        status = data.withUnsafeBytes { raw -> OSStatus in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress! + byteOffset, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard status == noErr else { return false }

        var sample: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block,
                                                                      formatDescription: format, sampleCount: frames,
                                                                      presentationTimeStamp: pts, packetDescriptions: nil,
                                                                      sampleBufferOut: &sample)
        guard status == noErr, let sample else { return false }
        if input.append(sample) { return true }
        noteFailure(in: track)
        return false
    }

    func finish(endTime: CMTime?, completion: @escaping (Error?) -> Void) {
        guard sessionStarted, writer.status == .writing else {
            // A failed take with frames (disk full / pulled out) keeps its file: it plays up to the last fragment.
            if writer.status != .failed || videoFramesWritten == 0 {
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: url)
            }
            completion(writer.error ?? MovieWriterError.cannotStart("no frames were written"))
            return
        }
        if let endTime { writer.endSession(atSourceTime: endTime) }
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        interfaceInput?.markAsFinished()
        timecodeInput?.markAsFinished()
        writer.finishWriting { [writer] in
            completion(writer.status == .completed ? nil : writer.error)
        }
    }

    func cancel() {
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: url)
    }
}
