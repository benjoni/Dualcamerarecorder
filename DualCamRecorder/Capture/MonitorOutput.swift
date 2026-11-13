//
//  MonitorOutput.swift
//  DualCamRecorder
//
//  Picture for a Blackmagic monitor on a DeckLink output (UltraStudio Monitor 3G, HD Mini …):
//  camera A, camera B or both side by side – live on the Record tab, the clip being played on Playback,
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

enum MonitorSource: String, CaseIterable, Identifiable {
    case a, b, both
    var id: String { rawValue }
}

/// Frames of the clip being played (Playback tab) or of the cut (Edit tab).
struct MonitorPlaybackFrames {
    var a: CVPixelBuffer?
    var b: CVPixelBuffer?
    /// Frame duration of the clip (25 fps when unknown).
    var frameDuration: CMTime
    /// Edit tab: `a` is the cut – always shown full, whatever camera choice the monitor has.
    var program = false
}

final class MonitorOutput: ObservableObject {
    /// "Sending 1080p25" / "Output device not connected" … (main queue).
    @Published private(set) var status = "Off"
    @Published private(set) var failed = false

    private let queue = DispatchQueue(label: "sk.dualcam.monitor-output", qos: .userInteractive)

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
    /// Viewing LUT of each camera on the live pictures only (clips in Playback / Edit go out as recorded).
    private var luts: [CameraRole: CubeLUT] = [:]
    private var lutRenders: [CameraRole: LUTRender] = [.a: LUTRender(), .b: LUTRender()]
    /// Info bar of each camera (operator, focus puller …) with the camera's name – on the live pictures only.
    private var infos: [CameraRole: (text: String, name: String)] = [:]
    /// Last laid-out text of each bar (made again only when the text or the bar's size changes).
    private var infoLines: [CameraRole: (key: String, line: CTLine, ascent: CGFloat, descent: CGFloat)] = [:]

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

    /// Viewing LUT of a camera's live picture (nil = none).
    func setLUT(_ lut: CubeLUT?, for role: CameraRole) {
        queue.async { [self] in
            luts[role] = lut
            renderLatest()
        }
    }

    /// Info bar of a camera's live picture ("" = no bar).
    func setInfo(_ text: String, name: String, for role: CameraRole) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        queue.async { [self] in
            infos[role] = trimmed.isEmpty ? nil : (trimmed, name)
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

    func submit(_ pixelBuffer: CVPixelBuffer, role: CameraRole) {
        queue.async { [self] in
            guard device != nil, playback == nil else { return }
            latest[role] = pixelBuffer
            let now = HostClock.nowNanos
            lastArrival[role] = now
            // Pace by the camera shown (both: camera A, or B when A stopped sending).
            let clock: CameraRole
            switch source {
            case .a: clock = .a
            case .b: clock = .b
            case .both:
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
        // Clips (Playback, Edit) go out as recorded – the LUT is for the live pictures only.
        let live = playback == nil
        let a = source == .b ? nil : latest[.a].map { live ? withLUT($0, role: .a) : $0 }
        let b = source == .a ? nil : latest[.b].map { live ? withLUT($0, role: .b) : $0 }
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
        guard let out = buffer(width: width, height: height, format: kCVPixelFormatType_422YpCbCr8) else { return }
        if source == .both && !program {
            guard let canvas = sideBySide(a: a, b: b, width: width, height: height) else { return }
            // Info bars on the black under each half picture (they cover nothing).
            if live {
                let halfW = width / 2, halfH = height / 2
                let barH = CGFloat(height) * 0.05
                let below = CGFloat((height - halfH) / 2)   // black under the pictures (bottom-up coordinates)
                for (index, role) in [CameraRole.a, .b].enumerated() where (index == 0 ? a : b) != nil {
                    guard let info = infos[role] else { continue }
                    drawInfo(info, role: role, in: canvas, background: 0.0,
                             rect: CGRect(x: CGFloat(index * halfW), y: below - barH - barH * 0.25, width: CGFloat(halfW), height: barH))
                }
            }
            guard copy(canvas, to: out) else { return }
        } else {
            guard let picture = a ?? b else { return }
            let role: CameraRole = a != nil ? .a : .b
            if live, let info = infos[role] {
                // One camera: the bar over the bottom of its picture, on a dark band.
                guard let canvas = buffer(width: width, height: height, format: kCVPixelFormatType_32BGRA),
                      copy(picture, to: canvas) else { return }
                drawInfo(info, role: role, in: canvas, background: 0.6,
                         rect: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height) * 0.06))
                guard copy(canvas, to: out) else { return }
            } else {
                guard copy(picture, to: out) else { return }
            }
        }
        _ = device.display(out)
    }

    /// Camera name (yellow) and the info text (white) in one line, on a band of black with the given opacity.
    /// `rect` in bottom-up coordinates of the BGRA picture; a text too long for the bar ends with "…".
    private func drawInfo(_ info: (text: String, name: String), role: CameraRole, in picture: CVPixelBuffer,
                          background: CGFloat, rect: CGRect) {
        CVPixelBufferLockBaseAddress(picture, [])
        defer { CVPixelBufferUnlockBaseAddress(picture, []) }
        guard let base = CVPixelBufferGetBaseAddress(picture),
              let space = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: base, width: CVPixelBufferGetWidth(picture), height: CVPixelBufferGetHeight(picture),
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(picture), space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        if background > 0 {
            ctx.setFillColor(CGColor(gray: 0, alpha: background))
            ctx.fill(rect)
        }
        let pad = rect.height * 0.4
        let key = "\(info.name)|\(info.text)|\(Int(rect.width))x\(Int(rect.height))"
        if infoLines[role]?.key != key {
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
            infoLines[role] = (key, line, ascent, descent)
        }
        guard let laid = infoLines[role] else { return }
        ctx.textPosition = CGPoint(x: rect.minX + pad, y: rect.midY - (laid.ascent - laid.descent) / 2)
        CTLineDraw(laid.line, ctx)
    }

    /// Live picture through the camera's LUT – converted to BGRA first, as the preview does.
    private func withLUT(_ picture: CVPixelBuffer, role: CameraRole) -> CVPixelBuffer {
        guard let lut = luts[role], let render = lutRenders[role] else { return picture }
        let rgb: CVPixelBuffer
        if CVPixelBufferGetPixelFormatType(picture) == kCVPixelFormatType_32BGRA {
            rgb = picture
        } else {
            guard let converted = buffer(width: CVPixelBufferGetWidth(picture), height: CVPixelBufferGetHeight(picture),
                                         format: kCVPixelFormatType_32BGRA), copy(picture, to: converted) else { return picture }
            CVBufferPropagateAttachments(picture, converted)
            rgb = converted
        }
        return render.apply(lut, to: rgb) ?? picture
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
            publish("Sending \(device.modeName ?? "\(width)×\(height)")", failed: false)
            return true
        } catch {
            running = nil
            startFailedFor = key
            publish(error.localizedDescription, failed: true)
            return false
        }
    }

    /// Both pictures at half size, centered left and right on black.
    private func sideBySide(a: CVPixelBuffer?, b: CVPixelBuffer?, width: Int, height: Int) -> CVPixelBuffer? {
        guard let canvas = buffer(width: width, height: height, format: kCVPixelFormatType_32BGRA) else { return nil }
        let halfW = width / 2, halfH = height / 2
        CVPixelBufferLockBaseAddress(canvas, [])
        defer { CVPixelBufferUnlockBaseAddress(canvas, []) }
        guard let base = CVPixelBufferGetBaseAddress(canvas) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(canvas)
        for y in 0..<height {   // opaque black
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt32.self)
            for x in 0..<width { row[x] = 0xFF00_0000 }
        }
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
        if let a = frames.a { latest[.a] = a }
        if let b = frames.b { latest[.b] = b }
        guard frames.a != nil || frames.b != nil else { return }   // paused: the monitor keeps the last frame
        let a = source == .b && !program ? nil : latest[.a]
        let b = source == .a || program ? nil : latest[.b]
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

    private func publish(_ text: String, failed: Bool) {
        DispatchQueue.main.async {
            if self.status != text { self.status = text }
            if self.failed != failed { self.failed = failed }
        }
    }
}
