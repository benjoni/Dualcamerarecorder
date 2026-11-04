//
//  SyncPlaybackController.swift
//  DualCamRecorder
//
//  Two AVPlayers locked to the same host clock. Start/stop/rate changes are issued with
//  setRate(_:time:atHostTime:) using one common host time, so both players map the same media time
//  to the same instant. Seeks and frame steps are frame-accurate (zero tolerance) on both players.
//

import Foundation
import AVFoundation
import QuartzCore
import CoreMedia
import Combine
import os

final class SyncPlaybackController: ObservableObject {
    let playerA = AVPlayer()
    let playerB = AVPlayer()

    @Published private(set) var take: Take?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var frameDuration = CMTime(value: 1, timescale: 25)
    @Published private(set) var abOffsetMs: Double?
    @Published var rate: Float = 1.0 {
        didSet { if isPlaying && oldValue != rate { play() } }
    }
    @Published var audioA = true { didSet { playerA.isMuted = !audioA } }
    @Published var audioB = false { didSet { playerB.isMuted = !audioB } }
    /// While the user drags the slider, periodic updates must not fight the slider.
    var isScrubbing = false
    /// IN / OUT of the loaded take (seconds).
    @Published private(set) var marks = TakeMarks()
    /// Loop: at OUT (or the end of the clip) jump back to IN (or the start) and keep playing.
    @Published var loopInOut = false {
        didSet {
            if loopInOut && loopClip { loopClip = false }
            if isPlaying && oldValue != loopInOut { play() }
        }
    }
    /// Loop the whole clip (start → end), IN / OUT are ignored. On by default.
    @Published var loopClip = true {
        didSet {
            if loopClip && loopInOut { loopInOut = false }
            if isPlaying && oldValue != loopClip { play() }
        }
    }
    /// The IN–OUT range is used only by "Loop IN/OUT"; "No" and "Clip" play the whole clip.
    private var useRange: Bool { loopInOut }
    @Published private(set) var marksMessage: String?
    /// Slate of the loaded take (nil for takes recorded without one).
    @Published private(set) var slate: SlateInfo?
    /// Camera timecode read from the files' timecode tracks (clips whose slate has none).
    @Published private(set) var fileTimecodeA: TimecodeRange?
    @Published private(set) var fileTimecodeB: TimecodeRange?

    /// Camera timecode of one file: from the slate, else from the file's timecode track.
    func timecodeRange(_ role: CameraRole) -> TimecodeRange? {
        slate?.timecode(role) ?? (role == .a ? fileTimecodeA : fileTimecodeB)
    }
    private var boundaryObserver: Any?
    private weak var boundaryPlayer: AVPlayer?

    // MARK: Waveform (luma) of both players
    let waveformA = WaveformModel()
    let waveformB = WaveformModel()
    /// Pull frames for the waveform only while it is shown (Playback tab + Waveform on).
    var waveformEnabled = false {
        didSet {
            guard oldValue != waveformEnabled else { return }
            waveformTimer?.invalidate()
            waveformTimer = nil
            if waveformEnabled {
                forceWaveformRefresh = true
                waveformTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
                    self?.updateWaveforms()
                }
            } else {
                waveformA.image = nil
                waveformB.image = nil
            }
        }
    }
    private var outputA: AVPlayerItemVideoOutput?
    private var outputB: AVPlayerItemVideoOutput?
    /// Own frame taps for the monitor output (read on the monitor's queue).
    fileprivate let monitorTaps = OSAllocatedUnfairLock<(a: AVPlayerItemVideoOutput?, b: AVPlayerItemVideoOutput?, frameDuration: CMTime)>(
        initialState: (nil, nil, CMTime(value: 1, timescale: 25)))
    private var waveformTimer: Timer?
    private var forceWaveformRefresh = false
    private let waveformQueue = DispatchQueue(label: "playback-waveform", qos: .utility)
    private var waveformBusy = false

    private var timeObservers: [Any] = []
    private var endObserver: NSObjectProtocol?
    private var generation = 0

    init() {
        for p in [playerA, playerB] {
            // Required for setRate(_:time:atHostTime:) – otherwise AVFoundation raises an exception.
            p.automaticallyWaitsToMinimizeStalling = false
            p.actionAtItemEnd = .pause
        }
        playerB.isMuted = true
        // Observe both players: a take recorded by camera B alone has no item in player A.
        timeObservers = [playerA, playerB].map { p in
            p.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self, weak p] _ in
                guard let self, let p, p === self.master else { return }
                self.updateTime()
            }
        }
    }

    deinit {
        for (p, o) in zip([playerA, playerB], timeObservers) { p.removeTimeObserver(o) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    /// Players that currently have media (a take may have only one camera).
    private var activePlayers: [AVPlayer] { [playerA, playerB].filter { $0.currentItem != nil } }
    private var master: AVPlayer? { activePlayers.first }

    // MARK: - Loading

    func load(_ take: Take?) {
        generation += 1
        pauseImmediately()
        self.take = take
        marks = take?.marks ?? TakeMarks()
        slate = take?.slate
        marksMessage = nil
        currentTime = 0
        duration = 0
        abOffsetMs = nil
        fileTimecodeA = nil
        fileTimecodeB = nil

        let itemA = take?.camA.map { AVPlayerItem(url: $0) }
        let itemB = take?.camB.map { AVPlayerItem(url: $0) }
        // Keep the audio pitch natural at 0.5× and 2×.
        itemA?.audioTimePitchAlgorithm = .spectral
        itemB?.audioTimePitchAlgorithm = .spectral
        // BGRA frame taps for the waveform monitor (do not affect the AVPlayerLayer).
        let bgra: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        outputA = itemA.map { item in
            let o = AVPlayerItemVideoOutput(pixelBufferAttributes: bgra)
            item.add(o)
            return o
        }
        outputB = itemB.map { item in
            let o = AVPlayerItemVideoOutput(pixelBufferAttributes: bgra)
            item.add(o)
            return o
        }
        let twoVuy: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_422YpCbCr8]
        let monitorA = itemA.map { item in
            let o = AVPlayerItemVideoOutput(pixelBufferAttributes: twoVuy)
            item.add(o)
            return o
        }
        let monitorB = itemB.map { item in
            let o = AVPlayerItemVideoOutput(pixelBufferAttributes: twoVuy)
            item.add(o)
            return o
        }
        monitorTaps.withLock { $0.a = monitorA; $0.b = monitorB }
        waveformA.image = nil
        waveformB.image = nil
        forceWaveformRefresh = true
        playerA.replaceCurrentItem(with: itemA)
        playerB.replaceCurrentItem(with: itemB)
        // Clip recorded by camera B alone: hear B.
        if itemA == nil, itemB != nil, !audioB { audioB = true }

        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        if let item = itemA ?? itemB {
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item,
                                                                 queue: .main) { [weak self] _ in
                guard let self else { return }
                self.isPlaying = false
                if self.loopInOut || self.loopClip { self.play() }   // restarts at IN (or the start)
            }
        }

        let gen = generation
        let assets = [itemA?.asset, itemB?.asset].compactMap { $0 }
        Task { @MainActor [weak self] in
            var longest = 0.0
            var fd: CMTime?
            for asset in assets {
                let assetDuration = (try? await asset.load(.duration)) ?? .zero
                longest = max(longest, assetDuration.seconds)
                if fd == nil {
                    let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
                    if let track = tracks.first {
                        let minFD = (try? await track.load(.minFrameDuration)) ?? .invalid
                        if minFD.isValid && minFD.seconds > 0 { fd = minFD }
                    }
                }
            }
            let tcA = itemA != nil && take?.slate?.timecodeA == nil ? await Self.readTimecode(of: itemA!.asset) : nil
            let tcB = itemB != nil && take?.slate?.timecodeB == nil ? await Self.readTimecode(of: itemB!.asset) : nil
            guard let self, self.generation == gen else { return }
            self.fileTimecodeA = tcA
            self.fileTimecodeB = tcB
            self.duration = longest
            if let fd {
                self.frameDuration = fd
                self.monitorTaps.withLock { $0.frameDuration = fd }
            }
            // Cue the take at IN.
            if let i = self.marks.firstInPoint { self.seek(seconds: i) }
        }
    }

    /// TC IN – OUT from the timecode track (`tmcd`, one 32-bit frame number) of a recorded file.
    private static func readTimecode(of asset: AVAsset) async -> TimecodeRange? {
        guard let track = try? await asset.loadTracks(withMediaType: .timecode).first,
              let video = try? await asset.loadTracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        defer { reader.cancelReading() }
        // A fragmented file first gives empty buffers – take the first one with a sample.
        var first: CMSampleBuffer?
        for _ in 0..<50 {
            guard let buffer = output.copyNextSampleBuffer() else { break }
            if CMSampleBufferGetNumSamples(buffer) > 0 { first = buffer; break }
        }
        guard let sample = first, let block = CMSampleBufferGetDataBuffer(sample),
              let format = CMSampleBufferGetFormatDescription(sample),
              CMFormatDescriptionGetMediaSubType(format) == kCMTimeCodeFormatType_TimeCode32 else { return nil }
        var raw: Int32 = 0
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: 4, destination: &raw) == noErr else { return nil }
        let base = max(1, Int(CMTimeCodeFormatDescriptionGetFrameQuanta(format)))
        let dropFrame = CMTimeCodeFormatDescriptionGetTimeCodeFlags(format) & kCMTimeCodeFlag_DropFrame != 0
        let start = Timecode(frameNumber: Int(Int32(bigEndian: raw)), base: base, dropFrame: dropFrame)
        let frames: Int
        if let count = try? await video.load(.timeRange).duration, let fd = try? await video.load(.minFrameDuration),
           fd.seconds > 0 {
            frames = max(1, Int((count.seconds / fd.seconds).rounded()))
        } else {
            frames = 1
        }
        return TimecodeRange(start: start, end: start.adding(frames: frames - 1, base: base), base: base)
    }

    // MARK: - Transport

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard let master else { return }
        generation += 1
        let gen = generation
        var start = master.currentTime()
        let fdSec = frameDuration.seconds > 0 ? frameDuration.seconds : 0.04
        // IN/OUT loop: only the marked ranges – inside one it plays on, else from the next one (after the last:
        // the first again).
        var rangeEnd: Double?
        let spans = useRange ? marks.spans(duration: duration) : []
        if let first = spans.first {
            let t = start.seconds
            if let inside = spans.first(where: { t >= $0.lowerBound - fdSec / 2 && t < $0.upperBound - fdSec / 2 }) {
                rangeEnd = inside.upperBound
            } else {
                let next = spans.first { $0.lowerBound > t } ?? first
                start = frameTime(seconds: next.lowerBound)
                rangeEnd = next.upperBound
            }
        } else if duration > 0 && start.seconds >= duration - fdSec {
            start = .zero
        }
        let players = activePlayers
        let rate = self.rate
        isPlaying = true
        removeBoundaryObserver()
        if let out = rangeEnd, out < duration - fdSec / 2, out > start.seconds {
            // Stop exactly at OUT.
            let outTime = frameTime(seconds: out)
            boundaryPlayer = master
            boundaryObserver = master.addBoundaryTimeObserver(forTimes: [NSValue(time: outTime)], queue: .main) { [weak self] in
                self?.stopAtOut(outTime)
            }
        }

        Task { @MainActor [weak self] in
            // Bring both players to exactly the same frame, preroll, then start on one common host time.
            for p in players {
                if p.rate != 0 { p.rate = 0 }
                _ = await p.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            for p in players where p.status == .readyToPlay {
                _ = await p.preroll(atRate: rate)
            }
            guard let self, self.generation == gen else { return }
            let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
            let hostStart = CMTimeAdd(hostNow, CMTime(value: 50, timescale: 1000))
            for p in players {
                p.setRate(rate, time: start, atHostTime: hostStart)
            }
        }
    }

    private func stopAtOut(_ outTime: CMTime) {
        guard isPlaying else { return }
        generation += 1
        removeBoundaryObserver()
        let hostStop = CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()), CMTime(value: 5, timescale: 1000))
        for p in activePlayers { p.setRate(0, time: .invalid, atHostTime: hostStop) }
        isPlaying = false
        if loopInOut {
            play()   // current time is at OUT → play() goes on with the next range (after the last: the first)
            return
        }
        seek(to: outTime)
    }

    private func removeBoundaryObserver() {
        if let boundaryObserver { boundaryPlayer?.removeTimeObserver(boundaryObserver) }
        boundaryObserver = nil
        boundaryPlayer = nil
    }

    func pause() {
        removeBoundaryObserver()
        generation += 1
        let gen = generation
        let players = activePlayers
        guard !players.isEmpty else { isPlaying = false; return }
        // Stop both at the same host instant → same media time.
        let hostStop = CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()), CMTime(value: 20, timescale: 1000))
        for p in players { p.setRate(0, time: .invalid, atHostTime: hostStop) }
        isPlaying = false
        // Then snap both to the exact frame shown by the master.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.generation == gen, let master = self.master else { return }
            self.seek(to: master.currentTime())
        }
    }

    private func pauseImmediately() {
        removeBoundaryObserver()
        for p in [playerA, playerB] { p.rate = 0 }
        isPlaying = false
    }

    /// Seek both players to `seconds`, snapped to the frame grid.
    func seek(seconds: Double) {
        seek(to: frameTime(seconds: seconds))
    }

    /// `seconds` snapped to the frame grid.
    private func frameTime(seconds: Double) -> CMTime {
        let fd = frameDuration.seconds > 0 ? frameDuration : CMTime(value: 1, timescale: 25)
        let frames = Int64((max(0, seconds) / fd.seconds).rounded())
        return CMTimeMultiply(fd, multiplier: Int32(clamping: frames))
    }

    // MARK: - IN / OUT

    private var currentFrameSeconds: Double {
        guard let master else { return 0 }
        return frameTime(seconds: master.currentTime().seconds).seconds
    }

    func setIn() {
        var m = marks
        m.setIn(currentFrameSeconds)
        updateMarks(m)
    }

    func setOut() {
        var m = marks
        if m.setOut(currentFrameSeconds) {
            updateMarks(m)
        } else {
            marksMessage = "OUT cannot be before IN."
        }
    }

    func clearMarks() { updateMarks(TakeMarks()) }

    /// Range under the play position, else the last one set.
    private var currentRange: ClosedRange<Double>? {
        let spans = marks.spans(duration: duration)
        return spans.first { $0.contains(currentTime) } ?? spans.last
    }

    func goToIn() { if let r = currentRange { seek(seconds: r.lowerBound) } }
    func goToOut() { if let r = currentRange { seek(seconds: r.upperBound) } }

    /// Saves edited slate data of the loaded take (C###_SLATE.JSON).
    func updateSlate(_ s: SlateInfo) {
        slate = s
        take?.slate = s
        guard let take, let folder = take.folder else { return }
        do {
            try TakeSlateStore.save(s, folder: folder, take: take.number)
        } catch {
            marksMessage = "Could not save the slate: \(error.localizedDescription)"
        }
    }

    private func updateMarks(_ m: TakeMarks) {
        marks = m
        take?.marks = m
        marksMessage = nil
        guard let take, let folder = take.folder else { return }
        do {
            try TakeMarksStore.save(m, folder: folder, take: take.number)
        } catch {
            marksMessage = "Could not save IN/OUT: \(error.localizedDescription)"
        }
    }

    private func seek(to time: CMTime) {
        let wasPlaying = isPlaying
        if wasPlaying {
            generation += 1
            pauseImmediately()
        }
        let players = activePlayers
        let gen = generation
        Task { @MainActor [weak self] in
            for p in players {
                _ = await p.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            guard let self, self.generation == gen else { return }
            self.updateTime()
            self.forceWaveformRefresh = true
            if wasPlaying { self.play() }
        }
    }

    /// Frame step (±n) on both players, frame-accurate.
    func step(_ frames: Int) {
        guard let master else { return }
        if isPlaying { pauseImmediately() }
        let target = CMTimeAdd(master.currentTime(), CMTimeMultiply(frameDuration, multiplier: Int32(frames)))
        let clamped = CMTimeClampToRange(target, range: CMTimeRange(start: .zero,
                                                                    duration: CMTime(seconds: max(0, duration - frameDuration.seconds),
                                                                                     preferredTimescale: 600)))
        generation += 1
        seek(to: clamped)
    }

    func goToStart() { seek(seconds: 0) }

    // MARK: - Waveform

    /// Grabs the frame currently shown by each player and renders its waveform off the main thread.
    private func updateWaveforms() {
        guard !waveformBusy else { return }
        let hostTime = CACurrentMediaTime()
        let force = forceWaveformRefresh
        forceWaveformRefresh = false
        var jobs: [(CVPixelBuffer, WaveformModel)] = []
        for (output, model) in [(outputA, waveformA), (outputB, waveformB)] {
            guard let output else { continue }
            let itemTime = output.itemTime(forHostTime: hostTime)
            guard force || output.hasNewPixelBuffer(forItemTime: itemTime) else { continue }
            if let pb = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {
                jobs.append((pb, model))
            } else if force {
                forceWaveformRefresh = true   // frame not decoded yet – try again next tick
            }
        }
        guard !jobs.isEmpty else { return }
        waveformBusy = true
        waveformQueue.async { [weak self] in
            let results = jobs.map { (WaveformRenderer.image(from: $0.0), $0.1) }
            DispatchQueue.main.async {
                for (image, model) in results { model.image = image }
                self?.waveformBusy = false
            }
        }
    }

    // MARK: - Time

    private func updateTime() {
        guard let master else { return }
        if !isScrubbing { currentTime = master.currentTime().seconds }
        if playerA.currentItem != nil && playerB.currentItem != nil {
            abOffsetMs = (playerB.currentTime().seconds - playerA.currentTime().seconds) * 1000
        } else {
            abOffsetMs = nil
        }
    }

    func timecode(_ seconds: Double) -> String {
        let fps = frameDuration.seconds > 0 ? 1 / frameDuration.seconds : 25
        let nominal = max(1, Int(fps.rounded()))
        let totalFrames = Int((seconds * fps).rounded())
        let f = totalFrames % nominal
        let s = totalFrames / nominal
        return String(format: "%02d:%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60, f)
    }
}

extension SyncPlaybackController {
    /// New frames of both cameras at this moment (nil = no new frame, e.g. paused). Any thread.
    func monitorFrames() -> MonitorPlaybackFrames {
        let taps = monitorTaps.withLock { $0 }
        func frame(_ output: AVPlayerItemVideoOutput?) -> CVPixelBuffer? {
            guard let output else { return nil }
            let time = output.itemTime(forHostTime: CACurrentMediaTime())
            guard output.hasNewPixelBuffer(forItemTime: time) else { return nil }
            return output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
        }
        return MonitorPlaybackFrames(a: frame(taps.a), b: frame(taps.b), frameDuration: taps.frameDuration)
    }
}
