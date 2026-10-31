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
    /// Play only between IN and OUT (start at IN, stop at OUT).
    @Published var limitToRange = true
    /// Loop: at OUT (or the end of the clip) jump back to IN (or the start) and keep playing.
    @Published var loopInOut = false {
        didSet { if isPlaying && oldValue != loopInOut { play() } }
    }
    /// The IN–OUT range is used when "Play IN–OUT only" or "Loop IN/OUT" is on.
    private var useRange: Bool { limitToRange || loopInOut }
    @Published private(set) var marksMessage: String?
    /// Slate of the loaded take (nil for takes recorded without one).
    @Published private(set) var slate: SlateInfo?
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
    private var waveformTimer: Timer?
    private var forceWaveformRefresh = false
    private let waveformQueue = DispatchQueue(label: "playback-waveform", qos: .utility)
    private var waveformBusy = false

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var generation = 0

    init() {
        for p in [playerA, playerB] {
            // Required for setRate(_:time:atHostTime:) – otherwise AVFoundation raises an exception.
            p.automaticallyWaitsToMinimizeStalling = false
            p.actionAtItemEnd = .pause
        }
        playerB.isMuted = true
        timeObserver = playerA.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] _ in
            self?.updateTime()
        }
    }

    deinit {
        if let timeObserver { playerA.removeTimeObserver(timeObserver) }
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
        waveformA.image = nil
        waveformB.image = nil
        forceWaveformRefresh = true
        playerA.replaceCurrentItem(with: itemA)
        playerB.replaceCurrentItem(with: itemB)

        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        if let item = itemA ?? itemB {
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item,
                                                                 queue: .main) { [weak self] _ in
                guard let self else { return }
                self.isPlaying = false
                if self.loopInOut { self.play() }   // restarts at IN (or the start)
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
            guard let self, self.generation == gen else { return }
            self.duration = longest
            if let fd { self.frameDuration = fd }
            // Cue the take at IN.
            if let i = self.marks.inPoint { self.seek(seconds: i) }
        }
    }

    // MARK: - Transport

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard let master else { return }
        generation += 1
        let gen = generation
        var start = master.currentTime()
        let fdSec = frameDuration.seconds > 0 ? frameDuration.seconds : 0.04
        if useRange && !marks.isEmpty {
            let lo = marks.inPoint ?? 0
            let hi = marks.outPoint ?? duration
            if start.seconds < lo - fdSec / 2 || start.seconds >= hi - fdSec / 2 {
                start = frameTime(seconds: lo)
            }
        } else if duration > 0 && start.seconds >= duration - fdSec {
            start = .zero
        }
        let players = activePlayers
        let rate = self.rate
        isPlaying = true
        removeBoundaryObserver()
        if useRange, let out = marks.outPoint, out > start.seconds {
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
            play()   // current time is at OUT → play() restarts both players at IN
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

    func goToIn() { if let i = marks.inPoint { seek(seconds: i) } }
    func goToOut() { if let o = marks.outPoint { seek(seconds: o) } }

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
