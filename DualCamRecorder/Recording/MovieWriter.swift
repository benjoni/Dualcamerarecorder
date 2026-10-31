//
//  MovieWriter.swift
//  DualCamRecorder
//
//  AVAssetWriter wrapper: ProRes 422 (.mov) video + uncompressed 24-bit LPCM audio.
//  Not thread-safe: use from one serial queue (CameraChannel.queue).
//

import Foundation
import AVFoundation
import CoreMedia
import CoreVideo

enum ProResFlavor: String, CaseIterable, Identifiable {
    case proRes422 = "422"
    case proRes422HQ = "422HQ"
    case proRes422LT = "422LT"

    var id: String { rawValue }

    var codec: AVVideoCodecType {
        switch self {
        case .proRes422: return .proRes422
        case .proRes422HQ: return .proRes422HQ
        case .proRes422LT: return .proRes422LT
        }
    }

    var title: String {
        switch self {
        case .proRes422: return "ProRes 422"
        case .proRes422HQ: return "ProRes 422 HQ"
        case .proRes422LT: return "ProRes 422 LT"
        }
    }

    /// Approximate bits per 1920×1080 frame (Apple ProRes white paper, 29.97p data rates ÷ 29.97).
    var approxBitsPerHDFrame: Double {
        switch self {
        case .proRes422: return 147_000_000 / 29.97
        case .proRes422HQ: return 220_000_000 / 29.97
        case .proRes422LT: return 102_000_000 / 29.97
        }
    }
}

enum MovieWriterError: LocalizedError {
    case cannotCreate(String)
    case cannotAddInput(String)
    case cannotStart(String)

    var errorDescription: String? {
        switch self {
        case .cannotCreate(let s): return "Nedá sa vytvoriť súbor: \(s)"
        case .cannotAddInput(let s): return "AVAssetWriter odmietol vstup: \(s)"
        case .cannotStart(let s): return "Zápis sa nespustil: \(s)"
        }
    }
}

final class MovieWriter {
    let url: URL
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioInput: AVAssetWriterInput?
    private let audioChannels: Int
    private var audioFormat: CMAudioFormatDescription?
    private(set) var videoFramesWritten = 0
    private(set) var audioSamplesWritten = 0
    private var sessionStarted = false

    init(url: URL, width: Int, height: Int, flavor: ProResFlavor, audioChannels: Int,
         metadata: [AVMetadataItem] = []) throws {
        self.url = url
        self.audioChannels = audioChannels
        if FileManager.default.fileExists(atPath: url.path) {
            throw MovieWriterError.cannotCreate("\(url.lastPathComponent) už existuje")
        }
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        } catch {
            throw MovieWriterError.cannotCreate(error.localizedDescription)
        }
        writer.metadata = metadata
        // Fragments keep the file recoverable if the app/computer dies mid-take.
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: flavor.codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(videoInput) else { throw MovieWriterError.cannotAddInput("video") }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        var audioFormat: CMAudioFormatDescription?
        if audioChannels > 0 {
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = audioChannels == 2
                ? kAudioChannelLayoutTag_Stereo
                : (kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(audioChannels))
            let layoutData = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: audioChannels,
                AVLinearPCMBitDepthKey: 24,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVChannelLayoutKey: layoutData,
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw MovieWriterError.cannotAddInput("audio") }
            writer.add(input)
            audioInput = input

            var asbd = AudioStreamBasicDescription(
                mSampleRate: 48_000,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                mBytesPerPacket: UInt32(4 * audioChannels),
                mFramesPerPacket: 1,
                mBytesPerFrame: UInt32(4 * audioChannels),
                mChannelsPerFrame: UInt32(audioChannels),
                mBitsPerChannel: 32,
                mReserved: 0)
            var fmt: CMAudioFormatDescription?
            CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                           magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                           formatDescriptionOut: &fmt)
            audioFormat = fmt
        }

        guard writer.startWriting() else {
            throw MovieWriterError.cannotStart(writer.error?.localizedDescription ?? "neznáma chyba")
        }
        self.writer = writer
        self.videoInput = videoInput
        self.adaptor = adaptor
        self.audioInput = audioInput
        self.audioFormat = audioFormat
    }

    var failed: Bool { writer.status == .failed }
    var errorDescription: String? { writer.error?.localizedDescription }

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
        return false
    }

    /// Appends `frames` interleaved Int32 sample frames starting at `offsetFrames` of `data`.
    @discardableResult
    func appendAudio(_ data: Data, offsetFrames: Int, frames: Int, at pts: CMTime) -> Bool {
        guard sessionStarted, let audioInput, let audioFormat, frames > 0,
              writer.status == .writing, audioInput.isReadyForMoreMediaData else { return false }
        let bytesPerFrame = 4 * audioChannels
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
                                                                      formatDescription: audioFormat, sampleCount: frames,
                                                                      presentationTimeStamp: pts, packetDescriptions: nil,
                                                                      sampleBufferOut: &sample)
        guard status == noErr, let sample else { return false }
        if audioInput.append(sample) {
            audioSamplesWritten += frames
            return true
        }
        return false
    }

    func finish(endTime: CMTime?, completion: @escaping (Error?) -> Void) {
        guard sessionStarted, writer.status == .writing else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            completion(writer.error ?? MovieWriterError.cannotStart("žiadne snímky neboli zapísané"))
            return
        }
        if let endTime { writer.endSession(atSourceTime: endTime) }
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        writer.finishWriting { [writer] in
            completion(writer.status == .completed ? nil : writer.error)
        }
    }

    func cancel() {
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: url)
    }
}
