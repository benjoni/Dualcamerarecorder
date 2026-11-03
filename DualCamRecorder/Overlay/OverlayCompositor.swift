//
//  OverlayCompositor.swift
//  DualCamRecorder
//
//  Overlay tab: one frame of a recorded clip (paused) with a live camera on top – to line up a new take
//  with an earlier one. Mix (opacity), Difference (black where both match) or Wipe (clip left, live right).
//  The clip frame is decoded and converted exactly like the live picture (VideoToolbox → BGRA, no colour
//  management), so Difference is really black where nothing changed. Composed on the GPU (Core Image)
//  whenever a live frame arrives or a setting changes; the result goes to the screen and the Blackmagic monitor.
//

import Foundation
import AVFoundation
import CoreImage
import VideoToolbox
import Combine
import os
import AppKit

enum OverlayMode: String, CaseIterable, Identifiable {
    case mix, difference, wipe
    var id: String { rawValue }
    var title: String {
        switch self {
        case .mix: return "Mix"
        case .difference: return "Difference"
        case .wipe: return "Wipe"
        }
    }
}

final class OverlayCompositor: ObservableObject, @unchecked Sendable {
    let displayLayer: AVSampleBufferDisplayLayer = {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        return layer
    }()

    // Settings (main thread); every change re-composes.
    @Published var liveRole: CameraRole = .a { didSet { update() } }
    @Published var mode: OverlayMode = .mix { didSet { update() } }
    /// 0 = only the clip, 1 = only the live camera (Mix).
    @Published var opacity: Double = 0.5 { didSet { update() } }
    /// Wipe line, 0 … 1 from the left.
    @Published var wipe: Double = 0.5 { didSet { update() } }
    /// "No picture from camera A" … (nil = live picture arriving).
    @Published private(set) var liveProblem: String? = "No live picture"

    /// The tab is visible: live frames are composed only then.
    var isActive: Bool {
        get { state.withLock { $0.active } }
        set {
            state.withLock { $0.active = newValue }
            if newValue { update() }
        }
    }

    private struct State {
        var active = false
        var liveRole = CameraRole.a
        var mode = OverlayMode.mix
        var opacity = 0.5
        var wipe = 0.5
        var still: CVPixelBuffer?
        var live: CVPixelBuffer?
        /// Demo: a picture instead of the live camera.
        var demoLive: CVPixelBuffer?
        var lastLiveNanos: UInt64 = 0
        var busy = false
        var composite: CVPixelBuffer?
        var frameDuration = CMTime(value: 1, timescale: 25)
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue = DispatchQueue(label: "overlay", qos: .userInitiated)
    private let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])
    private var transfer: VTPixelTransferSession?           // queue only
    private var pools: [String: CVPixelBufferPool] = [:]    // queue only
    private var problemTimer: Timer?

    init() {
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
        problemTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.checkLive() }
    }

    // MARK: - Input

    /// Every live picture of a camera (capture threads); only the chosen camera is used.
    func submitLive(_ picture: CVPixelBuffer, role: CameraRole) {
        let use = state.withLock { s -> Bool in
            guard s.active, role == s.liveRole, !s.busy else { return false }
            s.busy = true
            s.lastLiveNanos = HostClock.nowNanos
            return true
        }
        guard use else { return }
        queue.async { [self] in
            if let bgra = self.bgra(picture) { state.withLockUnchecked { $0.live = bgra } }
            compose()
        }
    }

    /// The clip frame (already converted with `bgra`), nil = no clip chosen.
    func setStill(_ still: CVPixelBuffer?, frameDuration: CMTime) {
        state.withLockUnchecked { $0.still = still; $0.frameDuration = frameDuration }
        update()
    }

    /// Demo without cameras: `picture` stands in for the live camera (nil = the real camera again).
    func setDemoLive(_ picture: CVPixelBuffer?) {
        state.withLockUnchecked { $0.demoLive = picture }
        checkLive()
        update()
    }

    /// Picture from the app's assets (DemoWide, DemoClose) as BGRA, like a camera frame.
    static func assetPicture(named name: String) -> CVPixelBuffer? {
        guard let image = NSImage(named: name)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &out)
        guard let out else { return nil }
        CVPixelBufferLockBaseAddress(out, [])
        defer { CVPixelBufferUnlockBaseAddress(out, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(out), width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(out), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return out
    }

    /// Composed picture for the Blackmagic monitor (any thread).
    var monitorFrames: MonitorPlaybackFrames {
        state.withLock { MonitorPlaybackFrames(a: $0.composite, frameDuration: $0.frameDuration, program: true) }
    }

    /// Frame of a file at `time` (the frame shown at that moment), converted like the live picture.
    func decodeFrame(url: URL, at time: CMTime) async -> CVPixelBuffer? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_422YpCbCr10,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.timeRange = CMTimeRange(start: time, duration: CMTime(value: 1, timescale: 10))
        guard reader.startReading(), let sample = output.copyNextSampleBuffer(),
              let picture = CMSampleBufferGetImageBuffer(sample) else { return nil }
        reader.cancelReading()
        return await withCheckedContinuation { done in
            queue.async { done.resume(returning: self.bgra(picture)) }
        }
    }

    // MARK: - Composing (queue)

    /// Settings → state, compose with the last live picture (also when the camera sends nothing).
    private func update() {
        let (role, mode, opacity, wipe) = (liveRole, self.mode, self.opacity, self.wipe)
        let changedRole = state.withLock { s -> Bool in
            let changed = s.liveRole != role
            s.liveRole = role; s.mode = mode; s.opacity = opacity; s.wipe = wipe
            if changed { s.live = nil }
            return changed
        }
        if changedRole { checkLive() }
        queue.async { self.compose() }
    }

    private func compose() {
        defer { state.withLock { $0.busy = false } }
        let s = state.withLock { $0 }
        guard s.active else { return }
        let live = (s.demoLive ?? s.live).map { CIImage(cvPixelBuffer: $0, options: [.colorSpace: NSNull()]) }
        let still = s.still.map { CIImage(cvPixelBuffer: $0, options: [.colorSpace: NSNull()]) }
        guard let base = live ?? still else { return }
        let extent = base.extent
        // The clip scaled to the live picture (same camera format: unchanged).
        let clip = still.map { fit($0, to: extent) }
        let picture: CIImage
        switch (clip, live) {
        case (let clip?, let live?):
            switch s.mode {
            case .mix:
                let faded = live.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(s.opacity))])
                picture = faded.composited(over: clip)
            case .difference:
                picture = live.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: clip])
            case .wipe:
                let x = extent.minX + extent.width * CGFloat(s.wipe)
                let right = live.cropped(to: CGRect(x: x, y: extent.minY, width: extent.maxX - x, height: extent.height))
                let line = CIImage(color: CIColor(red: 1, green: 0.85, blue: 0.1))
                    .cropped(to: CGRect(x: x - extent.width * 0.0015, y: extent.minY, width: extent.width * 0.003, height: extent.height))
                picture = line.composited(over: right.composited(over: clip))
            }
        case (let clip?, nil): picture = clip
        case (nil, let live?): picture = live
        default: return
        }
        guard let out = buffer(width: Int(extent.width), height: Int(extent.height)) else { return }
        context.render(picture.cropped(to: extent), to: out, bounds: extent, colorSpace: nil)
        state.withLockUnchecked { $0.composite = out }
        guard let sample = Self.sample(out) else { return }
        DispatchQueue.main.async {
            let renderer = self.displayLayer.sampleBufferRenderer
            if renderer.status == .failed { renderer.flush() }
            renderer.enqueue(sample)
        }
    }

    private func fit(_ image: CIImage, to extent: CGRect) -> CIImage {
        guard image.extent.size != extent.size else { return image }
        let scale = min(extent.width / image.extent.width, extent.height / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let dx = extent.midX - scaled.extent.midX, dy = extent.midY - scaled.extent.midY
        return scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy))
            .composited(over: CIImage(color: .black).cropped(to: extent))
    }

    /// Any camera / file format → BGRA of the same size (queue).
    private func bgra(_ picture: CVPixelBuffer) -> CVPixelBuffer? {
        guard let transfer,
              let out = buffer(width: CVPixelBufferGetWidth(picture), height: CVPixelBufferGetHeight(picture)),
              VTPixelTransferSessionTransferImage(transfer, from: picture, to: out) == noErr else { return nil }
        return out
    }

    private func buffer(width: Int, height: Int) -> CVPixelBuffer? {
        let key = "\(width)x\(height)"
        if pools[key] == nil {
            let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                             kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                                             kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
            pools[key] = pool
        }
        var out: CVPixelBuffer?
        guard let pool = pools[key], CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess else { return nil }
        return out
    }

    private static func sample(_ picture: CVPixelBuffer) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: picture, formatDescriptionOut: &format)
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: picture, formatDescription: format,
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        if let sample, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }

    #if DEBUG
    /// Debug snapshot: the composed picture as PNG.
    func debugCompositePNG() -> Data? {
        guard let picture = state.withLockUnchecked({ $0.composite }) else { return nil }
        let image = CIImage(cvPixelBuffer: picture, options: [.colorSpace: NSNull()])
        guard let cg = context.createCGImage(image, from: image.extent) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
    #endif

    /// "No live picture" when the chosen camera has sent nothing for a second (main thread);
    /// its last picture is then dropped, so the clip frame is not covered by a frozen live picture.
    private func checkLive() {
        let stale = state.withLock { s -> Bool in
            let fresh = s.lastLiveNanos > 0 && HostClock.nowNanos &- s.lastLiveNanos < 1_000_000_000
            guard !fresh else { return false }
            let had = s.live != nil
            s.live = nil
            return had
        }
        let fresh = state.withLockUnchecked { $0.demoLive != nil || ($0.lastLiveNanos > 0 && HostClock.nowNanos &- $0.lastLiveNanos < 1_000_000_000) }
        let problem: String? = fresh ? nil : "No live picture from this camera"
        if problem != liveProblem { liveProblem = problem }
        if stale { queue.async { self.compose() } }
    }
}
