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

    private struct State { var busy = false; var active = true }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue = DispatchQueue(label: "preview", qos: .userInitiated)
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
        let accepted = state.withLock { s -> Bool in
            guard s.active, !s.busy else { return false }
            s.busy = true
            return true
        }
        guard accepted else { return }
        queue.async { [weak self] in
            guard let self else { return }
            defer { self.state.withLock { $0.busy = false } }
            guard let sample = self.makePreviewSample(from: pixelBuffer) else { return }
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

    private func makePreviewSample(from source: CVPixelBuffer) -> CMSampleBuffer? {
        guard let transferSession, let pool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out) == kCVReturnSuccess, let dst = out else { return nil }
        guard VTPixelTransferSessionTransferImage(transferSession, from: source, to: dst) == noErr else { return nil }

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
