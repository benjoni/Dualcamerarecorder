//
//  MonitorOutput.swift
//  DualCamRecorder
//
//  Picture for a Blackmagic monitor on a DeckLink output (UltraStudio Monitor 3G, HD Mini …):
//  camera A, camera B, both side by side or both stacked for a monitor turned to portrait – live on the Record tab, the clip being played on Playback,
//  the cut (one full picture) on Edit.
//  The output runs in the format of the cameras (1080p25 …); frames go out as they come (no scheduling).
//

import Foundation
import Combine
import CoreMedia
import CoreVideo
import QuartzCore
import VideoToolbox
import CoreText
#if DEBUG
import AppKit
#endif

/// Where a piece of sound for the monitor comes from: the inputs (what is being recorded) or the clip played.
enum MonitorAudioKind { case live, playback }

enum MonitorSource: String, CaseIterable, Identifiable {
    /// `stackedRight` / `stackedLeft`: both cameras one above the other for a monitor turned 90° to the right
    /// (clockwise) / to the left – the picture goes out turned, so it stands upright on the portrait screen.
    case a, b, both, stackedRight, stackedLeft
    var id: String { rawValue }
    var showsBoth: Bool { self == .both || isStacked }
    var isStacked: Bool { self == .stackedRight || self == .stackedLeft }
}

/// Frames of the clip being played (Playback tab) or of the cut (Edit tab).
struct MonitorPlaybackFrames {
    var a: CVPixelBuffer?
    var b: CVPixelBuffer?
    /// Frame duration of the clip (25 fps when unknown).
    var frameDuration: CMTime
    /// Edit tab: `a` is the cut – always shown full, whatever camera choice the monitor has.
    var program = false
    /// Live edit on Playback: the camera in the cut gets the green frame.
    var cut: CameraRole?
}

final class MonitorOutput: ObservableObject {
    /// "Sending 1080p25" / "Output device not connected" … (main queue).
    @Published private(set) var status = "Off"
    @Published private(set) var failed = false

    private let queue = DispatchQueue(label: "sk.dualcam.monitor-output", qos: .userInteractive)
    /// Newest live frame of each camera not yet taken by the queue (capture threads → queue).
    private let inboxLock = NSLock()
    private var inbox: [CameraRole: (CVPixelBuffer, String?)] = [:]
    private var inboxScheduled: Set<CameraRole> = []

    // Queue only.
    private var device: DLOutputDevice?
    private var deviceID = ""
    private var source = MonitorSource.a
    private var formats: [CameraRole: VideoFormatInfo] = [:]
    private var latest: [CameraRole: CVPixelBuffer] = [:]
    private var lastArrival: [CameraRole: UInt64] = [:]
    private var running: (width: Int, height: Int, frameDuration: CMTime, interlaced: Bool)?
    private var startFailedFor: String?
    private var transfer: VTPixelTransferSession?
    private var pools: [String: CVPixelBufferPool] = [:]
    private var playback: (() -> MonitorPlaybackFrames)?
    private var playbackTimer: DispatchSourceTimer?
    private var busy = false
    /// The picture shown is the cut (one full picture, camera choice ignored).
    private var program = false
    /// Info bar of each camera (operator, focus puller …) with the camera's name – on the live pictures only.
    private var infos: [CameraRole: (text: String, name: String)] = [:]
    /// Live edit: the camera in the cut gets a green frame on the live pictures (nil = live edit off).
    private var liveCut: CameraRole?
    /// The same for the clip being played (live edit on Playback).
    private var playbackCut: CameraRole?
    /// Sound in the output: on / off and gain of the live sound and of the clip's (queue only).
    private var audioLive = (on: false, gain: Float(0.8))
    private var audioPlayback = (on: true, gain: Float(0.8))
    private var audioScratch: [Int32] = []
    /// Last laid-out text of each bar (made again only when the text or the bar's size changes).
    private var infoLines: [String: (key: String, line: CTLine, ascent: CGFloat, descent: CGFloat)] = [:]
    /// Camera names (for the bars), the cameras' own timecode of the last frame, and the slate line on top
    /// (the slate being recorded / the clip's slate on Playback).
    private var names: [CameraRole: String] = [:]
    private var timecodes: [CameraRole: String] = [:]
    private var slateLive = ""
    private var slatePlayback = ""

    // MARK: - Settings (main queue)

    /// Device "" = off. Called again when devices come and go.
    func configure(deviceID: String, source: MonitorSource, available: Bool) {
        queue.async { [self] in
            self.source = source
            if deviceID != self.deviceID || (device == nil && available) || !available {
                device?.stop()
                device = nil
                running = nil
                startFailedFor = nil
                self.deviceID = deviceID
                if !deviceID.isEmpty, available { device = DLOutputDevice(identifier: deviceID) }
            }
            if deviceID.isEmpty {
                publish("Off", failed: false)
            } else if device == nil {
                publish("Output device not connected", failed: true)
            } else {
                running = nil   // the source may need another format
                startFailedFor = nil
                renderLatest()
            }
            updatePlaybackTimer()
        }
    }

    /// Info bar of a camera's live picture ("" = no bar).
    func setInfo(_ text: String, name: String, for role: CameraRole) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        queue.async { [self] in
            infos[role] = trimmed.isEmpty ? nil : (trimmed, name)
            names[role] = name
            renderLatest()
        }
    }

    /// Slate line at the top of the monitor picture: the slate being recorded (live) and the clip's (Playback).
    func setSlate(live: String, playback: String) {
        queue.async { [self] in
            slateLive = live
            slatePlayback = playback
        }
    }

    /// Bar under a live picture: the camera's name, the info text and the camera's own timecode (nil = no bar).
    private func barInfo(_ role: CameraRole) -> (text: String, name: String)? {
        let parts = [infos[role]?.text, timecodes[role].map { "TC \($0)" }].compactMap { $0 }
        guard !parts.isEmpty else { return nil }
        return (parts.joined(separator: "   ·   "), infos[role]?.name ?? names[role] ?? role.rawValue.uppercased())
    }

    /// Draws the slate line into a band of the BGRA picture (`rect` bottom-up, before `transform`).
    private func drawSlate(_ text: String, in picture: CVPixelBuffer, rect: CGRect, background: CGFloat,
                           transform: CGAffineTransform = .identity) {
        guard !text.isEmpty else { return }
        drawInfo((text, "SLATE"), cache: "slate", in: picture, background: background, rect: rect, transform: transform)
    }

    /// Camera in the live cut (nil = live edit off).
    func setLiveCut(_ role: CameraRole?) {
        queue.async { [self] in
            guard liveCut != role else { return }
            liveCut = role
            renderLatest()
        }
    }

    /// Input format of a camera (nil = no signal / no device).
    func setFormat(_ format: VideoFormatInfo?, for role: CameraRole) {
        queue.async { [self] in
            formats[role] = format
            if format == nil { latest[role] = nil }
        }
    }

    /// Sound in the output: the live sound (Record, and Playback when the monitor stays live) and the clip's.
    func setAudio(liveOn: Bool, liveVolume: Double, playbackOn: Bool, playbackVolume: Double) {
        queue.async { [self] in
            audioLive = (liveOn, Float(min(max(liveVolume, 0), 1)))
            audioPlayback = (playbackOn, Float(min(max(playbackVolume, 0), 1)))
        }
    }

    /// Interleaved Int32 PCM at 48 kHz (any number of channels – the first two go out, one channel goes to both).
    /// Used when it is the kind of sound the output plays now and it is switched on; any thread.
    func submitAudio(_ data: Data, frames: Int, channels: Int, kind: MonitorAudioKind) {
        guard frames > 0, channels > 0, data.count >= frames * channels * 4 else { return }
        queue.async { [self] in
            guard let device, running != nil, device.audioEnabled else { return }
            let live = playback == nil
            guard live == (kind == .live) else { return }
            let setting = live ? audioLive : audioPlayback
            guard setting.on, setting.gain > 0 else { return }
            if audioScratch.count < frames * 2 { audioScratch = [Int32](repeating: 0, count: frames * 2) }
            let gain = setting.gain
            data.withUnsafeBytes { raw in
                let src = raw.bindMemory(to: Int32.self)
                for i in 0..<frames {
                    let l = Float(src[i * channels]) * gain
                    let r = channels > 1 ? Float(src[i * channels + 1]) * gain : l
                    audioScratch[i * 2] = Int32(max(min(l, Float(Int32.max - 64)), Float(Int32.min)))
                    audioScratch[i * 2 + 1] = Int32(max(min(r, Float(Int32.max - 64)), Float(Int32.min)))
                }
            }
            audioScratch.withUnsafeBufferPointer { _ = device.writeAudio($0.baseAddress!, frames: UInt32(frames)) }
        }
    }

    /// Playback tab: frames come from the players instead of the inputs (nil = live inputs).
    func setPlayback(_ provider: (() -> MonitorPlaybackFrames)?) {
        queue.async { [self] in
            playback = provider
            program = false
            latest = [:]   // no live frame next to a clip (and back)
            updatePlaybackTimer()
        }
    }

    // MARK: - Live frames (capture threads)

    func submit(_ pixelBuffer: CVPixelBuffer, role: CameraRole, timecode: Timecode? = nil) {
        // At most one waiting frame per camera: when a picture takes longer than a frame to make, the older
        // frame is replaced instead of queued – otherwise the queue grows and the monitor falls seconds behind.
        inboxLock.lock()
        inbox[role] = (pixelBuffer, timecode?.string)
        let schedule = inboxScheduled.insert(role).inserted
        inboxLock.unlock()
        guard schedule else { return }
        queue.async { [self] in
            inboxLock.lock()
            let newest = inbox.removeValue(forKey: role)
            inboxScheduled.remove(role)
            inboxLock.unlock()
            guard let (pixelBuffer, tc) = newest, device != nil, playback == nil else { return }
            latest[role] = pixelBuffer
            timecodes[role] = tc
            let now = HostClock.nowNanos
            lastArrival[role] = now
            // Pace by the camera shown (both: camera A, or B when A stopped sending).
            let clock: CameraRole
            switch source {
            case .a: clock = .a
            case .b: clock = .b
            case .both, .stackedRight, .stackedLeft:
                let aFresh = lastArrival[.a].map { now &- $0 < 200_000_000 } ?? false
                clock = aFresh ? .a : .b
            }
            guard role == clock else { return }
            renderLatest()
        }
    }

    // MARK: - Rendering (queue)

    private func renderLatest() {
        guard let device, !busy else { return }
        let live = playback == nil
        let a = source == .b ? nil : latest[.a]
        let b = source == .a ? nil : latest[.b]
        guard a != nil || b != nil else { return }
        let format = formats[source == .b ? .b : .a] ?? formats[.b] ?? formats[.a]
        let size = format.map { (Int($0.width), Int($0.height)) } ?? size(of: (a ?? b)!)
        send(a: a, b: b, width: size.0, height: size.1,
             frameDuration: format?.frameDuration ?? CMTime(value: 1, timescale: 25),
             interlaced: format?.interlaced ?? false, device: device, live: live)
    }

    private func send(a: CVPixelBuffer?, b: CVPixelBuffer?, width: Int, height: Int,
                      frameDuration: CMTime, interlaced: Bool, device: DLOutputDevice, live: Bool = false) {
        busy = true
        defer { busy = false }
        if !ensureRunning(width: width, height: height, frameDuration: frameDuration, interlaced: interlaced, device: device) { return }
        guard let out = compose(a: a, b: b, width: width, height: height, live: live) else { return }
        #if DEBUG
        let start = HostClock.nowNanos
        #endif
        _ = device.display(out)
        #if DEBUG
        debugTrace(display: HostClock.nowNanos - start, live: live)
        #endif
    }

    #if DEBUG
    private var traceCount = 0, traceDisplay: UInt64 = 0, traceAge: UInt64 = 0, traceStart: UInt64 = 0
    /// Debug only: every 5 s the average time of the display call and the age of the live frame sent (NSLog).
    private func debugTrace(display: UInt64, live: Bool) {
        let now = HostClock.nowNanos
        if traceStart == 0 { traceStart = now }
        traceCount += 1; traceDisplay += display
        if live, let arrival = lastArrival.values.max() { traceAge += now &- arrival }
        guard now - traceStart > 5_000_000_000 else { return }
        NSLog("monitor: %d frames in %.1f s, display %.1f ms, frame age %.1f ms", traceCount,
              Double(now - traceStart) / 1e9, Double(traceDisplay) / 1e6 / Double(traceCount),
              Double(traceAge) / 1e6 / Double(traceCount))
        traceCount = 0; traceDisplay = 0; traceAge = 0; traceStart = now
    }
    #endif

    /// The picture for the output (2vuy, in the output's format), nil when it could not be made.
    private func compose(a: CVPixelBuffer?, b: CVPixelBuffer?, width: Int, height: Int, live: Bool) -> CVPixelBuffer? {
        guard let out = buffer(width: width, height: height, format: kCVPixelFormatType_422YpCbCr8) else { return nil }
        // Live edit: the camera in the cut (live pictures or the clip being played; never on the cut itself).
        let cut = program ? nil : (live ? liveCut : playbackCut)
        // Slate line on top: live = the slate being recorded, Playback = the clip's (not on the Edit cut).
        let slate = program ? "" : (live ? slateLive : slatePlayback)
        if source.isStacked {
            guard let canvas = stacked(a: program ? (a ?? b) : a, b: program ? nil : b, width: width, height: height,
                                       live: live && !program, single: program, cut: cut, slate: slate),
                  copy(canvas, to: out) else { return nil }
        } else if source == .both && !program {
            guard let canvas = sideBySide(a: a, b: b, width: width, height: height) else { return nil }
            // Slate line in the black above the pictures.
            let halfH0 = height / 2
            let above = CGFloat(height - (height - halfH0) / 2)   // top edge of the pictures (bottom-up)
            let slateH = CGFloat(height) * 0.05
            drawSlate(slate, in: canvas, rect: CGRect(x: 0, y: above + (CGFloat(height) - above - slateH) / 2,
                                                      width: CGFloat(width), height: slateH), background: 0)
            // Info bars on the black under each half picture (they cover nothing) – live pictures only.
            if live || cut != nil {
                let halfW = width / 2, halfH = height / 2
                let barH = CGFloat(height) * 0.05
                let below = CGFloat((height - halfH) / 2)   // black under the pictures (bottom-up coordinates)
                for (index, role) in [CameraRole.a, .b].enumerated() where (index == 0 ? a : b) != nil {
                    if cut == role {
                        drawCutFrame(in: canvas, rect: CGRect(x: CGFloat(index * halfW), y: CGFloat((height - halfH) / 2),
                                                              width: CGFloat(halfW), height: CGFloat(halfH)))
                    }
                    guard live, let info = barInfo(role) else { continue }
                    drawInfo(info, cache: role.rawValue, in: canvas, background: 0.0,
                             rect: CGRect(x: CGFloat(index * halfW), y: below - barH - barH * 0.25, width: CGFloat(halfW), height: barH))
                }
            }
            guard copy(canvas, to: out) else { return nil }
        } else {
            guard let picture = a ?? b else { return nil }
            let role: CameraRole = a != nil ? .a : .b
            if (live && barInfo(role) != nil) || cut == role || !slate.isEmpty {
                // One camera: the bar over the bottom of its picture and the slate over the top, on dark bands;
                // the cut frame around it.
                guard let canvas = buffer(width: width, height: height, format: kCVPixelFormatType_32BGRA),
                      copy(picture, to: canvas) else { return nil }
                drawSlate(slate, in: canvas, rect: CGRect(x: 0, y: CGFloat(height) * 0.94, width: CGFloat(width),
                                                          height: CGFloat(height) * 0.06), background: 0.6)
                if live, let info = barInfo(role) {
                    drawInfo(info, cache: role.rawValue, in: canvas, background: 0.6,
                             rect: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height) * 0.06))
                }
                if cut == role {
                    drawCutFrame(in: canvas, rect: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
                }
                guard copy(canvas, to: out) else { return nil }
            } else {
                guard copy(picture, to: out) else { return nil }
            }
        }
        return out
    }

    /// Camera name (yellow) and the info text (white) in one line, on a band of black with the given opacity.
    /// `rect` in bottom-up coordinates of the BGRA picture; a text too long for the bar ends with "…".
    private func drawInfo(_ info: (text: String, name: String), cache: String, in picture: CVPixelBuffer,
                          background: CGFloat, rect: CGRect, transform: CGAffineTransform = .identity) {
        CVPixelBufferLockBaseAddress(picture, [])
        defer { CVPixelBufferUnlockBaseAddress(picture, []) }
        guard let base = CVPixelBufferGetBaseAddress(picture),
              let space = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: base, width: CVPixelBufferGetWidth(picture), height: CVPixelBufferGetHeight(picture),
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(picture), space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        ctx.concatenate(transform)
        if background > 0 {
            ctx.setFillColor(CGColor(gray: 0, alpha: background))
            ctx.fill(rect)
        }
        let pad = rect.height * 0.4
        let key = "\(info.name)|\(info.text)|\(Int(rect.width))x\(Int(rect.height))"
        if infoLines[cache]?.key != key {
            let size = rect.height * 0.6
            let bold = CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil)
                ?? CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
            let regular = CTFontCreateUIFontForLanguage(.system, size, nil) ?? bold
            let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
            let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
            let text = NSMutableAttributedString(string: info.name + "   ",
                                                 attributes: [fontKey: bold, colorKey: CGColor(red: 1, green: 0.84, blue: 0.04, alpha: 1)])
            text.append(NSAttributedString(string: info.text, attributes: [fontKey: regular, colorKey: CGColor(gray: 1, alpha: 1)]))
            let full = CTLineCreateWithAttributedString(text)
            let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: [fontKey: regular, colorKey: CGColor(gray: 1, alpha: 1)]))
            let line = CTLineCreateTruncatedLine(full, Double(rect.width - 2 * pad), .end, token) ?? full
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            infoLines[cache] = (key, line, ascent, descent)
        }
        guard let laid = infoLines[cache] else { return }
        ctx.textPosition = CGPoint(x: rect.minX + pad, y: rect.midY - (laid.ascent - laid.descent) / 2)
        CTLineDraw(laid.line, ctx)
    }

    /// Green frame (live edit: this camera is in the cut) along the inside of `rect` of the BGRA picture.
    private func drawCutFrame(in picture: CVPixelBuffer, rect: CGRect, transform: CGAffineTransform = .identity) {
        CVPixelBufferLockBaseAddress(picture, [])
        defer { CVPixelBufferUnlockBaseAddress(picture, []) }
        guard let base = CVPixelBufferGetBaseAddress(picture),
              let space = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: base, width: CVPixelBufferGetWidth(picture), height: CVPixelBufferGetHeight(picture),
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(picture), space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        ctx.concatenate(transform)
        let line = max(6, (rect.height * 0.012).rounded())
        ctx.setStrokeColor(CGColor(red: 0.1, green: 0.85, blue: 0.25, alpha: 1))
        ctx.setLineWidth(line)
        ctx.stroke(rect.insetBy(dx: line / 2, dy: line / 2))
    }

    /// Output mode follows the shown picture's format; started again only when it changes.
    private func ensureRunning(width: Int, height: Int, frameDuration: CMTime, interlaced: Bool, device: DLOutputDevice) -> Bool {
        if let r = running, r.width == width, r.height == height, r.frameDuration == frameDuration, r.interlaced == interlaced {
            return true
        }
        let key = "\(width)x\(height)/\(frameDuration.value)/\(frameDuration.timescale)/\(interlaced)"
        if startFailedFor == key { return false }
        do {
            try device.start(width: Int32(width), height: Int32(height), frameDuration: frameDuration.value,
                             timeScale: Int64(frameDuration.timescale), interlaced: interlaced)
            running = (width, height, frameDuration, interlaced)
            startFailedFor = nil
            publish("Sending \(device.modeName ?? "\(width)×\(height)")" + (device.audioEnabled ? " with sound" : ""), failed: false)
            return true
        } catch {
            running = nil
            startFailedFor = key
            publish(error.localizedDescription, failed: true)
            return false
        }
    }

    /// Portrait monitor: A above B (or one picture, `single`), each as wide as the turned screen, with its info bar
    /// under it – drawn upright on the portrait screen and turned into the landscape output picture.
    private func stacked(a: CVPixelBuffer?, b: CVPixelBuffer?, width: Int, height: Int, live: Bool, single: Bool,
                         cut: CameraRole? = nil, slate: String = "") -> CVPixelBuffer? {
        guard let canvas = buffer(width: width, height: height, format: kCVPixelFormatType_32BGRA) else { return nil }
        // The portrait screen: as wide as the output is high and as high as it is wide (bottom-up coordinates).
        let screenW = CGFloat(height), screenH = CGFloat(width)
        let turn = source == .stackedRight
            ? CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: screenH, ty: 0)    // monitor turned clockwise
            : CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: screenW)    // monitor turned counter-clockwise
        let picW = Int(screenW), picH = (Int(screenW * screenW / screenH) + 1) / 2 * 2   // the camera's aspect (16:9)
        let barH = (screenW * 0.065).rounded()
        let gap = (screenW * 0.03).rounded()
        let pictures: [(CameraRole, CVPixelBuffer?)] = single ? [(.a, a)] : [(.a, a), (.b, b)]
        let block = CGFloat(picH) + (live ? barH + gap : 0)
        let total = block * CGFloat(pictures.count) + (pictures.count > 1 ? gap * 2 : 0)
        var top = screenH - (screenH - total) / 2   // from the top of the portrait screen down
        var slots: [(role: CameraRole, picture: CVPixelBuffer?, rect: CGRect, bar: CGRect)] = []
        for (role, picture) in pictures {
            let rect = CGRect(x: 0, y: top - CGFloat(picH), width: CGFloat(picW), height: CGFloat(picH))
            let bar = CGRect(x: 0, y: rect.minY - gap * 0.5 - barH, width: screenW, height: barH)
            slots.append((role, picture, rect, bar))
            top -= block + gap * 2
        }
        CVPixelBufferLockBaseAddress(canvas, [])
        guard let base = CVPixelBufferGetBaseAddress(canvas),
              let space = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(canvas), space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { CVPixelBufferUnlockBaseAddress(canvas, []); return nil }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.concatenate(turn)
        ctx.interpolationQuality = .medium
        for slot in slots {
            guard let picture = slot.picture,
                  let scaled = buffer(width: picW, height: picH, format: kCVPixelFormatType_32BGRA),
                  copy(picture, to: scaled) else { continue }
            var image: CGImage?
            VTCreateCGImageFromCVPixelBuffer(scaled, options: nil, imageOut: &image)
            if let image { ctx.draw(image, in: slot.rect) }
        }
        CVPixelBufferUnlockBaseAddress(canvas, [])
        for slot in slots where slot.picture != nil {
            if cut == slot.role { drawCutFrame(in: canvas, rect: slot.rect, transform: turn) }
            if live, let info = barInfo(slot.role) {
                drawInfo(info, cache: slot.role.rawValue, in: canvas, background: 0, rect: slot.bar, transform: turn)
            }
        }
        // Slate line in the free space above the first picture (top of the portrait screen).
        if let first = slots.first {
            let free = screenH - first.rect.maxY
            let h = min(barH, free * 0.8)
            if h > 10 {
                drawSlate(slate, in: canvas, rect: CGRect(x: 0, y: first.rect.maxY + (free - h) / 2, width: screenW, height: h),
                          background: 0, transform: turn)
            }
        }
        return canvas
    }

    /// Both pictures at half size, centered left and right on black.
    private func sideBySide(a: CVPixelBuffer?, b: CVPixelBuffer?, width: Int, height: Int) -> CVPixelBuffer? {
        guard let canvas = buffer(width: width, height: height, format: kCVPixelFormatType_32BGRA) else { return nil }
        let halfW = width / 2, halfH = height / 2
        CVPixelBufferLockBaseAddress(canvas, [])
        defer { CVPixelBufferUnlockBaseAddress(canvas, []) }
        guard let base = CVPixelBufferGetBaseAddress(canvas) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(canvas)
        var black: UInt32 = 0xFF00_0000   // opaque black (one call for the whole picture – a pixel loop is far too slow)
        memset_pattern4(base, &black, rowBytes * height)
        for (index, picture) in [a, b].enumerated() {
            guard let picture, let half = buffer(width: halfW, height: halfH, format: kCVPixelFormatType_32BGRA),
                  copy(picture, to: half) else { continue }
            CVPixelBufferLockBaseAddress(half, .readOnly)
            if let src = CVPixelBufferGetBaseAddress(half) {
                let srcRow = CVPixelBufferGetBytesPerRow(half)
                let top = (height - halfH) / 2
                for y in 0..<halfH {
                    memcpy(base.advanced(by: (top + y) * rowBytes + index * halfW * 4),
                           src.advanced(by: y * srcRow), halfW * 4)
                }
            }
            CVPixelBufferUnlockBaseAddress(half, .readOnly)
        }
        return canvas
    }

    /// Scales and converts (2vuy / v210 / BGRA → anything).
    private func copy(_ source: CVPixelBuffer, to destination: CVPixelBuffer) -> Bool {
        if transfer == nil {
            var session: VTPixelTransferSession?
            VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session)
            transfer = session
        }
        guard let transfer else { return false }
        return VTPixelTransferSessionTransferImage(transfer, from: source, to: destination) == noErr
    }

    private func buffer(width: Int, height: Int, format: OSType) -> CVPixelBuffer? {
        let key = "\(width)x\(height)/\(format)"
        if pools[key] == nil {
            let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: format,
                                             kCVPixelBufferWidthKey as String: width,
                                             kCVPixelBufferHeightKey as String: height,
                                             kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 4] as CFDictionary,
                                    attributes as CFDictionary, &pool)
            pools[key] = pool
        }
        guard let pool = pools[key] else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        return out
    }

    private func size(of buffer: CVPixelBuffer) -> (Int, Int) {
        (CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer))
    }

    // MARK: - Playback (queue)

    private func updatePlaybackTimer() {
        playbackTimer?.cancel()
        playbackTimer = nil
        guard playback != nil, device != nil else { return }
        let fps = running.map { $0.frameDuration.seconds > 0 ? 1 / $0.frameDuration.seconds : 25 } ?? 25
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1 / fps, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.playbackTick() }
        timer.resume()
        playbackTimer = timer
    }

    private func playbackTick() {
        guard let device, let playback else { return }
        let frames = playback()
        program = frames.program
        playbackCut = frames.cut
        if let a = frames.a { latest[.a] = a }
        if let b = frames.b { latest[.b] = b }
        guard frames.a != nil || frames.b != nil else { return }   // paused: the monitor keeps the last frame
        let a = source == .b && !program ? nil : latest[.a]
        let b = source == .a || program ? nil : latest[.b]   // (stacked: both, like side by side)
        guard a != nil || b != nil else { return }
        // Keep the cameras' format when it is known (no mode switch on the monitor), otherwise the clip's.
        let format = formats[.a] ?? formats[.b]
        let size = format.map { (Int($0.width), Int($0.height)) } ?? size(of: (a ?? b)!)
        let before = running?.frameDuration
        send(a: a, b: b, width: size.0, height: size.1,
             frameDuration: format?.frameDuration ?? frames.frameDuration,
             interlaced: format?.interlaced ?? false, device: device)
        if running?.frameDuration != before { updatePlaybackTimer() }
    }

    #if DEBUG
    /// Debug: the output picture for these frames as PNG (no device needed).
    func debugPicture(a: CVPixelBuffer?, b: CVPixelBuffer?, source: MonitorSource, width: Int = 1920, height: Int = 1080,
                      program: Bool = false) -> Data? {
        queue.sync {
            let saved = (self.source, self.program)
            self.source = source; self.program = program
            defer { (self.source, self.program) = saved }
            let a2 = source == .b && !program ? nil : a
            let b2 = source == .a || program ? nil : b
            guard let out = compose(a: a2, b: b2, width: width, height: height, live: !program),
                  let bgra = buffer(width: width, height: height, format: kCVPixelFormatType_32BGRA),
                  copy(out, to: bgra) else { return nil }
            var image: CGImage?
            VTCreateCGImageFromCVPixelBuffer(bgra, options: nil, imageOut: &image)
            return image.flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
        }
    }
    #endif

    #if DEBUG
    /// Debug only: the cameras' timecode as if it came with the frames.
    func debugSetTimecodes(_ values: [CameraRole: String]) {
        queue.sync { timecodes = values }
    }

    /// Debug only: milliseconds to make one output picture (average of `count`).
    func debugComposeMillis(a: CVPixelBuffer?, b: CVPixelBuffer?, source: MonitorSource, count: Int = 50) -> Double {
        queue.sync {
            let saved = self.source
            self.source = source
            defer { self.source = saved }
            let a2 = source == .b ? nil : a, b2 = source == .a ? nil : b
            _ = compose(a: a2, b: b2, width: 1920, height: 1080, live: true)
            let start = HostClock.nowNanos
            for _ in 0..<count { _ = compose(a: a2, b: b2, width: 1920, height: 1080, live: true) }
            return Double(HostClock.nowNanos - start) / 1e6 / Double(count)
        }
    }
    #endif

    private func publish(_ text: String, failed: Bool) {
        DispatchQueue.main.async {
            if self.status != text { self.status = text }
            if self.failed != failed { self.failed = failed }
        }
    }
}
