//
//  SimulatedSource.swift
//  DualCamRecorder
//
//  Test pattern source used when no DeckLink hardware is attached.
//  Both simulated cameras share one host-clock epoch, so the burnt-in frame counter and the
//  once-per-second white flash + 1 kHz beep can be used to verify A/B sync in playback.
//  Camera B runs with a sub-frame phase offset to mimic two un-genlocked cameras.
//

import Foundation
import CoreMedia
import CoreVideo
import CoreGraphics
import CoreText
import AppKit

final class SimulatedSource: VideoSource {
    weak var delegate: VideoSourceDelegate?
    let displayName: String

    /// Common epoch for all simulated sources.
    private static let epochNanos: UInt64 = HostClock.nowNanos

    private let label: String
    private let phaseOffset: Double          // fraction of a frame
    private let audioChannels: Int
    private let fps: Int32 = 25
    private let width = 1920
    private let height = 1080
    private let hue: CGFloat

    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private var pool: CVPixelBufferPool?
    private var background: [UInt8] = []
    private var lastIndex: Int64 = -1

    init(label: String, phaseOffset: Double, audioChannels: Int, hue: CGFloat) {
        self.label = label
        self.displayName = "Simulovaný vstup \(label)"
        self.phaseOffset = phaseOffset
        self.audioChannels = audioChannels
        self.hue = hue
        self.queue = DispatchQueue(label: "sim.\(label)", qos: .userInteractive)
    }

    private var frameNanos: UInt64 { UInt64(1_000_000_000 / Int64(fps)) }

    func start() throws {
        stop()
        queue.sync {
            self.makePool()
            self.renderBackground()
            self.lastIndex = -1
        }
        let format = VideoFormatInfo(modeName: "SIM 1080p\(fps)", width: width, height: height,
                                     frameDuration: CMTime(value: 1, timescale: fps),
                                     interlaced: false, rgb444: true, bitDepth: 8,
                                     pixelFormat: kCVPixelFormatType_32BGRA)
        DispatchQueue.main.async { self.delegate?.videoSource(self, didDetectFormat: format) }

        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now(), repeating: .nanoseconds(Int(frameNanos) / 4), leeway: .nanoseconds(0))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    // MARK: - Frame generation

    private func tick() {
        let offset = UInt64(phaseOffset * Double(frameNanos))
        let now = HostClock.nowNanos
        let base = Self.epochNanos + offset
        guard now >= base else { return }
        let index = Int64((now - base) / frameNanos)
        guard index != lastIndex else { return }
        var dropped = 0
        if lastIndex >= 0 && index > lastIndex + 1 { dropped = Int(index - lastIndex - 1) }
        lastIndex = index

        guard let pb = renderFrame(index: index) else { return }
        let hostTime = base + UInt64(index) * frameNanos
        let audio = audioChannels > 0 ? makeAudio(index: index) : nil
        let frame = CapturedFrame(pixelBuffer: pb,
                                  streamTime: CMTime(value: index, timescale: fps),
                                  duration: CMTime(value: 1, timescale: fps),
                                  hostTimeNanos: hostTime,
                                  hasSignal: true,
                                  droppedBefore: dropped,
                                  audio: audio)
        delegate?.videoSource(self, didCapture: frame)
    }

    private func makePool() {
        let attrs: [String: Any] = [
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        let poolAttrs: [String: Any] = [kCVPixelBufferPoolMinimumBufferCountKey as String: 12]
        var p: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttrs as CFDictionary, attrs as CFDictionary, &p)
        pool = p
    }

    /// Pre-renders color bars once; per frame we only memcpy and draw the dynamic parts.
    private func renderBackground() {
        let bytesPerRow = width * 4
        background = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colors: [NSColor] = [.white, .yellow, .cyan, .green, .magenta, .red, .blue, .black]
        background.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return }
            let barWidth = CGFloat(width) / CGFloat(colors.count)
            for (i, c) in colors.enumerated() {
                ctx.setFillColor(c.cgColor)
                ctx.fill(CGRect(x: CGFloat(i) * barWidth, y: CGFloat(height) * 0.33, width: barWidth, height: CGFloat(height) * 0.67))
            }
            ctx.setFillColor(NSColor(hue: hue, saturation: 0.6, brightness: 0.35, alpha: 1).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height) * 0.33))
        }
    }

    private func renderFrame(index: Int64) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out) == kCVReturnSuccess, let pb = out else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(pb)
        background.withUnsafeBytes { src in
            let srcRow = width * 4
            for y in 0..<height {
                memcpy(base + y * rowBytes, src.baseAddress! + y * srcRow, srcRow)
            }
        }
        guard let ctx = CGContext(data: base, width: width, height: height, bitsPerComponent: 8, bytesPerRow: rowBytes,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }

        let f = Int64(fps)
        let frameInSecond = index % f
        let totalSeconds = index / f
        let tc = String(format: "%02lld:%02lld:%02lld:%02lld",
                        (totalSeconds / 3600) % 24, (totalSeconds / 60) % 60, totalSeconds % 60, frameInSecond)

        // Sync flash: first frame of every second.
        if frameInSecond == 0 {
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 1560, y: 40, width: 320, height: 260))
        }
        // Moving sweep bar – one revolution per second.
        let x = CGFloat(frameInSecond) / CGFloat(f) * CGFloat(width - 40)
        ctx.setFillColor(CGColor(red: 1, green: 0.2, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: x, y: 330, width: 40, height: 60))

        draw(text: "CAM \(label)  SIMULÁCIA", at: CGPoint(x: 60, y: 220), size: 72, in: ctx)
        draw(text: tc, at: CGPoint(x: 60, y: 90), size: 110, in: ctx)
        draw(text: "frame \(index)", at: CGPoint(x: 900, y: 100), size: 48, in: ctx)

        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        return pb
    }

    private func draw(text: String, at point: CGPoint, size: CGFloat, in ctx: CGContext) {
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, size, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs) as CFAttributedString)
        ctx.textPosition = point
        CTLineDraw(line, ctx)
    }

    /// 48 kHz Int32 interleaved: 1 kHz beep during the flash frame, silence otherwise.
    private func makeAudio(index: Int64) -> CapturedAudio {
        let samplesPerFrame = Int(48_000 / fps)
        var samples = [Int32](repeating: 0, count: samplesPerFrame * audioChannels)
        if index % Int64(fps) == 0 {
            let amplitude = Double(Int32.max) * 0.25
            for i in 0..<samplesPerFrame {
                let v = Int32(amplitude * sin(2 * Double.pi * 1000 * Double(i) / 48_000))
                for c in 0..<audioChannels { samples[i * audioChannels + c] = v }
            }
        }
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        return CapturedAudio(data: data, sampleFrames: samplesPerFrame, channels: audioChannels,
                             packetTime: index * Int64(samplesPerFrame))
    }
}
