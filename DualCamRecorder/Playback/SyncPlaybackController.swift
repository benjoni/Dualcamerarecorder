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
        currentTime = 0
        duration = 0
        abOffsetMs = nil

        let itemA = take?.camA.map { AVPlayerItem(url: $0) }
        let itemB = take?.camB.map { AVPlayerItem(url: $0) }
        playerA.replaceCurrentItem(with: itemA)
        playerB.replaceCurrentItem(with: itemB)

        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        if let item = itemA ?? itemB {
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item,
                                                                 queue: .main) { [weak self] _ in
                self?.isPlaying = false
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
        }
    }

    // MARK: - Transport

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard let master else { return }
        generation += 1
        let gen = generation
        var start = master.currentTime()
        if duration > 0 && start.seconds >= duration - frameDuration.seconds { start = .zero }
        let players = activePlayers
        let rate = self.rate
        isPlaying = true

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

    func pause() {
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
        for p in [playerA, playerB] { p.rate = 0 }
        isPlaying = false
    }

    /// Seek both players to `seconds`, snapped to the frame grid.
    func seek(seconds: Double) {
        let fd = frameDuration.seconds > 0 ? frameDuration : CMTime(value: 1, timescale: 25)
        let frames = Int64((max(0, seconds) / fd.seconds).rounded())
        seek(to: CMTimeMultiply(fd, multiplier: Int32(clamping: frames)))
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
