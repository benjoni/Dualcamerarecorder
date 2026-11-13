//
//  PreviewRenderer.swift
//  DualCamRecorder
//
//  Downscales captured frames (any format incl. v210) to a small BGRA buffer with VideoToolbox
//  and shows them in an AVSampleBufferDisplayLayer. Runs on its own queue and simply skips frames
//  while busy, so preview can never back-pressure capture or recording.
//

import Foundation
import AVFoundation
import VideoToolbox
import CoreMedia
import os
import ImageIO
import UniformTypeIdentifiers

final class PreviewRenderer {
    let displayLayer: AVSampleBufferDisplayLayer = {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        return layer
    }()

    /// Set by the view – when false, frames are ignored (saves GPU while the tab is hidden).
    var isActive: Bool {
        get { state.withLock { $0.active } }
        set { state.withLock { $0.active = newValue } }
    }

    /// Luma waveform of this camera (updated ~12× per second while enabled).
    let waveform = WaveformModel()
    var waveformEnabled: Bool {
        get { state.withLock { $0.waveform } }
        set {
            state.withLock { $0.waveform = newValue }
            if !newValue { DispatchQueue.main.async { self.waveform.image = nil } }
        }
    }

    private struct State {
        var busy = false; var active = true; var waveform = false; var stream = false
        var streamQuality = LiveViewQuality.standard; var jpegBusy = false
        var lut: CubeLUT?
    }
    /// Viewing LUT on the screen, the waveform and the phones (nil = none).
    var lut: CubeLUT? {
        get { state.withLock { $0.lut } }
        set { state.withLock { $0.lut = newValue } }
    }
    private let lutRender = LUTRender()         // preview queue only
    private let streamLUTRender = LUTRender()   // preview queue only
    private var lastWaveformNanos: UInt64 = 0   // preview queue only
    private var lastJPEGNanos: UInt64 = 0       // preview queue only

    /// Live view for phones: JPEGs are produced while this is on, even when the
    /// picture itself is not on screen (e.g. Playback tab).
    var streamEnabled: Bool {
        get { state.withLock { $0.stream } }
        set { state.withLock { $0.stream = newValue } }
    }
    /// Size, rate and JPEG quality of the pictures for phones.
    var streamQuality: LiveViewQuality {
        get { state.withLock { $0.streamQuality } }
        set { state.withLock { $0.streamQuality = newValue } }
    }
    /// Receives the JPEGs (called on the JPEG queue).
    var onJPEG: ((Data) -> Void)?
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue = DispatchQueue(label: "preview", qos: .userInitiated)
    /// JPEG encoding runs here so it never delays the on-screen preview.
    private let jpegQueue = DispatchQueue(label: "preview-jpeg", qos: .utility)
    private var streamPool: CVPixelBufferPool?    // preview queue only
    private var streamPoolWidth = 0               // preview queue only
    private var transferSession: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private let outWidth = 960
    private let outHeight = 540

    init() {
        var session: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session)
        transferSession = session
        let attrs: [String: Any] = [
            kCVPixelBufferWidthKey as String: outWidth,
            kCVPixelBufferHeightKey as String: outHeight,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        var p: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &p)
        pool = p
    }

    /// Thread-safe; drops the frame if the previous one is still being processed.
    func enqueue(_ pixelBuffer: CVPixelBuffer) {
        let flags = state.withLock { s -> (accepted: Bool, display: Bool) in
            guard s.active || s.stream, !s.busy else { return (false, false) }
            s.busy = true
            return (true, s.active)
        }
        guard flags.accepted else { return }
        let display = flags.display
        queue.async { [weak self] in
            guard let self else { return }
            defer { self.state.withLock { $0.busy = false } }
            let lut = self.lut
            guard let scaled = self.scaledPicture(from: pixelBuffer) else { return }
            let small = lut.flatMap { self.lutRender.apply($0, to: scaled) } ?? scaled
            guard let sample = Self.sample(for: small) else { return }
            // Waveform from the already downscaled BGRA picture, ~12 Hz.
            let now = HostClock.nowNanos
            if self.waveformEnabled, now - self.lastWaveformNanos > 80_000_000 {
                self.lastWaveformNanos = now
                let image = WaveformRenderer.image(from: small)
                DispatchQueue.main.async { self.waveform.image = image }
            }
            // JPEG for phones; skipped while the previous one is still being encoded.
            let quality = self.streamQuality
            if self.streamEnabled, now - self.lastJPEGNanos > quality.frameIntervalNanos, let onJPEG = self.onJPEG,
               self.beginJPEG() {
                self.lastJPEGNanos = now
                let picture = quality.width == self.outWidth ? small : self.streamPicture(from: pixelBuffer, quality: quality)
                    .map { stream in lut.flatMap { self.streamLUTRender.apply($0, to: stream) } ?? stream }
                if let picture {
                    self.jpegQueue.async {
                        defer { self.state.withLock { $0.jpegBusy = false } }
                        if let jpeg = Self.jpeg(from: picture, quality: quality.jpegQuality) { onJPEG(jpeg) }
                    }
                } else {
                    self.state.withLock { $0.jpegBusy = false }
                }
            }
            guard display else { return }
            DispatchQueue.main.async {
                let renderer = self.displayLayer.sampleBufferRenderer
                if renderer.status == .failed { renderer.flush() }
                renderer.enqueue(sample)
            }
        }
    }

    func clear() {
        DispatchQueue.main.async {
            self.displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        }
    }

    private func beginJPEG() -> Bool {
        state.withLock { s in
            if s.jpegBusy { return false }
            s.jpegBusy = true
            return true
        }
    }

    /// Source frame scaled to the live view size when it differs from the 960×540 preview.
    private func streamPicture(from source: CVPixelBuffer, quality: LiveViewQuality) -> CVPixelBuffer? {
        guard let transferSession else { return nil }
        if streamPool == nil || streamPoolWidth != quality.width {
            let attrs: [String: Any] = [
                kCVPixelBufferWidthKey as String: quality.width,
                kCVPixelBufferHeightKey as String: quality.height,
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &p)
            streamPool = p
            streamPoolWidth = quality.width
        }
        guard let streamPool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, streamPool, &out) == kCVReturnSuccess, let dst = out,
              VTPixelTransferSessionTransferImage(transferSession, from: source, to: dst) == noErr else { return nil }
        return dst
    }

    /// BGRA → JPEG (640×360 … 1280×720, ~40–200 kB).
    private static func jpeg(from pixelBuffer: CVPixelBuffer, quality: Double) -> Data? {
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &image)
        guard let image else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// Source frame scaled to the 960×540 BGRA preview.
    private func scaledPicture(from source: CVPixelBuffer) -> CVPixelBuffer? {
        guard let transferSession, let pool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out) == kCVReturnSuccess, let dst = out else { return nil }
        guard VTPixelTransferSessionTransferImage(transferSession, from: source, to: dst) == noErr else { return nil }
        return dst
    }

    private static func sample(for dst: CVPixelBuffer) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: dst, formatDescriptionOut: &format)
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: dst,
                                                 formatDescription: format, sampleTiming: &timing,
                                                 sampleBufferOut: &sample)
        guard let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}
