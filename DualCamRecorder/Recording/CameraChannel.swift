//
//  CameraChannel.swift
//  DualCamRecorder
//
//  One camera path: source → (preview, writer). All recording decisions happen on `queue`.
//
//  Start/stop alignment between cameras:
//    The controller hands both channels the same host-clock instants (startHostNanos / stopHostNanos).
//    A frame is part of the take when  start − ½ frame ≤ hostTime < stop − ½ frame.
//    hostTime is the DeckLink hardware timestamp converted to the shared host clock (see DLCapture.mm),
//    so the first frame of A and B are at most ½ frame apart (the cameras are not genlocked).
//

import Foundation
import CoreMedia
import AVFoundation
import CoreVideo
import VideoToolbox
import Combine
import os

enum CameraRole: String, CaseIterable, Identifiable {
    case a = "A"
    case b = "B"
    var id: String { rawValue }
    var fileSuffix: String { "Cam\(rawValue)" }
}

struct ChannelStats: Equatable {
    var framesCaptured = 0
    var inputDropped = 0          // lost on the SDI/DeckLink side (stream-time gaps)
    var writerDropped = 0         // encoder/disk could not keep up
    var framesWritten = 0
    var noSignalFrames = 0
    /// Most frames waiting for the writer in the last 0.1 s (0 … 10; 10 = frames are being dropped).
    var writeBacklog = 0

    var totalDropped: Int { inputDropped + writerDropped }
}

struct ChannelTakeResult {
    var role: CameraRole
    var url: URL
    var firstFrameHostNanos: UInt64?
    var framesWritten: Int
    var error: String?
    /// Camera timecode of the first and last written frame (nil: the camera sent none).
    var timecode: TimecodeRange? = nil
}

/// Timecode and REC state of the camera, updated every frame (separate from CameraChannel so only the
/// small views showing them redraw).
final class CameraSignalInfo: ObservableObject {
    @Published fileprivate(set) var timecode: Timecode?
    /// Frame duration (s) of the signal carrying `timecode`.
    @Published fileprivate(set) var frameDuration: Double = 0
    /// Host time of the frame with `timecode` (comparing the timecode of two cameras).
    fileprivate(set) var timecodeHostNanos: UInt64 = 0
    @Published fileprivate(set) var cameraRec = CameraRecState.unknown
    /// REC comes from the camera's record flag (false: from the running timecode).
    @Published fileprivate(set) var recFromFlag = false
    /// SDI data log being written (file name).
    @Published fileprivate(set) var sdiLog: URL?

    var base: Int { Timecode.base(frameDuration: frameDuration) }
}

final class CameraChannel: ObservableObject, VideoSourceDelegate {
    let role: CameraRole
    let preview = PreviewRenderer()
    let signal = CameraSignalInfo()
    /// Every captured picture (capture thread) – the monitor output. Set once at start.
    var onPicture: ((CVPixelBuffer) -> Void)?
    /// The camera started / stopped recording (main thread).
    var onCameraRecChange: ((CameraRecState) -> Void)?

    // Published on main.
    @Published private(set) var sourceName: String = "—"
    @Published private(set) var format: VideoFormatInfo?
    @Published private(set) var hasSignal = false
    @Published private(set) var stats = ChannelStats()
    @Published private(set) var audioLevelDB: Float = -120
    @Published private(set) var isRecording = false
    @Published private(set) var lastError: String?

    private var source: VideoSource?
    private let queue: DispatchQueue

    /// Flip / flop (capture thread): every picture is turned before preview, monitor and writer.
    private struct Turn {
        var orientation = PictureOrientation()
        var session: VTPixelRotationSession?
        var pool: CVPixelBufferPool?
        var poolKey: (format: OSType, width: Int, height: Int)?
    }
    private let turn = OSAllocatedUnfairLock(initialState: Turn())
    private let recDetection = OSAllocatedUnfairLock(initialState: CameraRecDetection.flag)

    // Pending work on `queue` – used to detect a backlog (disk/encoder too slow).
    private let backlog = OSAllocatedUnfairLock(initialState: 0)
    private let maxBacklog = 10

    // ---- state confined to `queue` ----
    private var qStats = ChannelStats()
    private var qPeak: Float = 0
    private var qHasSignal = false
    private var lastPublishNanos: UInt64 = 0
    private var lastFrameSize: (width: Int, height: Int)?
    private var backlogPeak = 0
    private var take: TakeState?
    // Camera timecode / REC (queue).
    private var qTimecode: Timecode?
    private var qTimecodeNanos: UInt64 = 0
    private var qFrameDuration: CMTime = .zero
    private var qTCMoving = 0
    private var qTCStill = 0
    private var qCamRec = CameraRecState.unknown
    private var qCandidate = CameraRecState.unknown
    private var qCandidateFrames = 0
    private var sdiLog: SDIDataLog?

    private struct TakeState {
        var writer: MovieWriter
        var startHostNanos: UInt64
        var stopHostNanos: UInt64?
        var firstStreamTime: CMTime?
        var firstHostNanos: UInt64?
        var lastPTS: CMTime = .zero
        var lastDuration: CMTime = .zero
        var completion: (ChannelTakeResult) -> Void
        var statsAtStart: ChannelStats
        /// Camera timecode of the first written frame and the timecode base (timecode track).
        var firstTimecode: Timecode?
        var timecodeBase = 25
        var lastTimecode: Timecode?
    }

    #if DEBUG
    private static let debugWriteDelay = useconds_t(max(0, UserDefaults.standard.integer(forKey: "debugWriteDelay")))
    #endif

    init(role: CameraRole) {
        self.role = role
        self.queue = DispatchQueue(label: "channel.\(role.rawValue)", qos: .userInteractive)
    }

    // MARK: - Source management (main thread)

    func setSource(_ newSource: VideoSource?) {
        if isRecording { return }
        source?.stop()
        source?.delegate = nil
        source = newSource
        format = nil
        hasSignal = false
        lastError = nil
        preview.clear()
        queue.async {
            self.qStats = ChannelStats()
            self.lastFrameSize = nil
            self.qHasSignal = false
            self.qTimecode = nil
            self.qCamRec = .unknown
            self.qCandidate = .unknown
        }
        signal.timecode = nil
        signal.cameraRec = .unknown
        stats = ChannelStats()
        guard let newSource else {
            sourceName = "—"
            return
        }
        sourceName = newSource.displayName
        newSource.delegate = self
        newSource.captureAncillary = signal.sdiLog != nil
        do {
            try newSource.start()
        } catch {
            lastError = error.localizedDescription
        }
    }

    var hasSource: Bool { source != nil }

    /// Picture turned round from the next frame on (not while recording – see the Record buttons).
    func setOrientation(_ orientation: PictureOrientation) {
        turn.withLock { t in
            guard t.orientation != orientation else { return }
            t.orientation = orientation
            if let session = t.session { VTPixelRotationSessionInvalidate(session) }
            t.session = nil
            guard orientation.isTurned else { return }
            var session: VTPixelRotationSession?
            guard VTPixelRotationSessionCreate(nil, &session) == noErr, let session else { return }
            VTSessionSetProperty(session, key: kVTPixelRotationPropertyKey_FlipVerticalOrientation,
                                 value: orientation.flip ? kCFBooleanTrue : kCFBooleanFalse)
            VTSessionSetProperty(session, key: kVTPixelRotationPropertyKey_FlipHorizontalOrientation,
                                 value: orientation.flop ? kCFBooleanTrue : kCFBooleanFalse)
            t.session = session
        }
    }

    /// The picture flipped / flopped (same format and size, colour tags kept); unchanged when not turned.
    private func turned(_ picture: CVPixelBuffer) -> CVPixelBuffer {
        turn.withLockUnchecked { t in
            guard let session = t.session else { return picture }
            let format = CVPixelBufferGetPixelFormatType(picture)
            let width = CVPixelBufferGetWidth(picture), height = CVPixelBufferGetHeight(picture)
            if t.poolKey.map({ $0.format != format || $0.width != width || $0.height != height }) ?? true {
                let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: format,
                                                 kCVPixelBufferWidthKey as String: width,
                                                 kCVPixelBufferHeightKey as String: height,
                                                 kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
                var pool: CVPixelBufferPool?
                CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 4] as CFDictionary, attributes as CFDictionary, &pool)
                t.pool = pool
                t.poolKey = (format, width, height)
            }
            var out: CVPixelBuffer?
            guard let pool = t.pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out,
                  VTPixelRotationSessionRotateImage(session, picture, out) == noErr else { return picture }
            CVBufferPropagateAttachments(picture, out)
            return out
        }
    }

    func resetCounters() {
        queue.async {
            self.qStats = ChannelStats()
            let s = self.qStats
            DispatchQueue.main.async { self.stats = s }
        }
    }

    // MARK: - Recording control (main thread)

    /// Creates the writer now (so the first frame does not pay for it) and arms the channel to start at `startHostNanos`.
    func arm(url: URL, startHostNanos: UInt64, flavor: ProResFlavor, audioChannels: Int,
             metadata: [AVMetadataItem] = [],
             completion: @escaping (ChannelTakeResult) -> Void) -> String? {
        var failure: String?
        queue.sync {
            guard take == nil else { failure = "Camera \(role.rawValue) is already recording."; return }
            guard let size = lastFrameSize else { failure = "Camera \(role.rawValue): no picture from the input."; return }
            // Timecode track when the camera sent timecode in the last second.
            var track: MovieWriter.TimecodeTrack?
            if let tc = qTimecode, HostClock.nowNanos - qTimecodeNanos < 1_000_000_000, qFrameDuration.seconds > 0 {
                track = .init(frameDuration: qFrameDuration, base: Timecode.base(frameDuration: qFrameDuration.seconds),
                              dropFrame: tc.dropFrame)
            }
            do {
                let writer = try MovieWriter(url: url, width: size.width, height: size.height,
                                             flavor: flavor, audioChannels: audioChannels,
                                             metadata: metadata, timecode: track)
                take = TakeState(writer: writer, startHostNanos: startHostNanos, completion: completion,
                                 statsAtStart: qStats)
            } catch {
                failure = "Camera \(role.rawValue): \(error.localizedDescription)"
            }
        }
        if failure == nil { isRecording = true }
        return failure
    }

    /// Cancels an armed take that has not been finished (used if the other camera failed to arm).
    func cancelArmed() {
        queue.sync {
            take?.writer.cancel()
            take = nil
        }
        isRecording = false
    }

    func requestStop(atHostNanos stopNanos: UInt64) {
        queue.async {
            guard self.take != nil else { return }
            self.take?.stopHostNanos = stopNanos
        }
        // Fallback if frames stop arriving (signal lost): finish 1 s after the stop instant.
        let delay = Double(Int64(stopNanos) - Int64(HostClock.nowNanos)) / 1e9 + 1.0
        queue.asyncAfter(deadline: .now() + max(0.1, delay)) { [weak self] in
            guard let self, self.take?.stopHostNanos != nil else { return }
            self.finishTake()
        }
    }

    // MARK: - VideoSourceDelegate

    func videoSource(_ source: VideoSource, didCapture captured: CapturedFrame) {
        var frame = captured
        frame.pixelBuffer = turned(captured.pixelBuffer)
        preview.enqueue(frame.pixelBuffer)
        onPicture?(frame.pixelBuffer)

        let limit = maxBacklog
        let overloaded = backlog.withLock { count -> Bool in
            if count >= limit { return true }
            count += 1
            return false
        }
        if overloaded {
            queue.async { self.qStats.writerDropped += 1 }
            return
        }
        queue.async {
            self.process(frame)
            self.backlog.withLock { $0 -= 1 }
        }
    }

    func videoSource(_ source: VideoSource, didDetectFormat format: VideoFormatInfo) {
        guard source === self.source else { return }
        self.format = format
    }

    func videoSource(_ source: VideoSource, didFail message: String) {
        guard source === self.source else { return }
        lastError = message
    }

    // MARK: - Frame processing (queue)

    private func process(_ frame: CapturedFrame) {
        qStats.framesCaptured += 1
        backlogPeak = max(backlogPeak, backlog.withLock { $0 })
        qStats.inputDropped += frame.droppedBefore
        if !frame.hasSignal { qStats.noSignalFrames += 1 }
        qHasSignal = frame.hasSignal
        lastFrameSize = (CVPixelBufferGetWidth(frame.pixelBuffer), CVPixelBufferGetHeight(frame.pixelBuffer))
        if let audio = frame.audio { qPeak = max(qPeak, Self.peak(of: audio)) }
        readCamera(frame)
        sdiLog?.add(frame)

        if take != nil {
            #if DEBUG
            if Self.debugWriteDelay > 0 { usleep(Self.debugWriteDelay) }   // -debugWriteDelay <µs>: a slow disk
            #endif
            record(frame)
        }
        publishIfNeeded()
    }

    private func record(_ frame: CapturedFrame) {
        guard var t = take else { return }
        let halfFrame = UInt64(max(0, HostClock.nanos(frame.duration) / 2))

        // Not yet at the common start instant.
        if t.firstStreamTime == nil && frame.hostTimeNanos + halfFrame < t.startHostNanos {
            return
        }
        // Past the common stop instant → close the file (this frame is not part of the take).
        if let stop = t.stopHostNanos, frame.hostTimeNanos + halfFrame >= stop {
            finishTake()
            return
        }

        if t.firstStreamTime == nil {
            t.firstStreamTime = frame.streamTime
            t.firstHostNanos = frame.hostTimeNanos
            t.writer.startSession()
        }
        guard let first = t.firstStreamTime else { return }

        let pts = CMTimeSubtract(frame.streamTime, first)
        if t.writer.appendVideo(frame.pixelBuffer, at: pts) {
            qStats.framesWritten += 1
            t.lastPTS = pts
            t.lastDuration = frame.duration
            // Continuous timecode track counted from the first frame's camera timecode.
            if t.writer.hasTimecodeTrack, frame.duration.seconds > 0 {
                if t.firstTimecode == nil, let tc = frame.timecode {
                    t.firstTimecode = tc
                    t.timecodeBase = Timecode.base(frameDuration: frame.duration.seconds)
                }
                if let start = t.firstTimecode {
                    let offset = Int((pts.seconds / frame.duration.seconds).rounded())
                    let tc = start.adding(frames: offset, base: t.timecodeBase)
                    t.writer.appendTimecode(frameNumber: tc.frameNumber(base: t.timecodeBase), at: pts, duration: frame.duration)
                    t.lastTimecode = tc
                }
            }
        } else {
            qStats.writerDropped += 1
        }

        if let audio = frame.audio {
            // Audio packet time and video stream time share the DeckLink stream timeline.
            let first48k = CMTimeConvertScale(first, timescale: 48_000, method: .roundHalfAwayFromZero).value
            var rel = audio.packetTime - first48k
            var skip = 0
            if rel < 0 { skip = Int(-rel); rel = 0 }
            if skip < audio.sampleFrames {
                t.writer.appendAudio(audio.data, offsetFrames: skip, frames: audio.sampleFrames - skip,
                                     at: CMTime(value: rel, timescale: 48_000))
            }
        }

        if t.writer.failed {
            let message = t.writer.errorDescription ?? "Writing failed"
            DispatchQueue.main.async { self.lastError = message }
            take = t
            finishTake()
            return
        }
        take = t
    }

    private func finishTake() {
        guard let t = take else { return }
        take = nil
        let endTime: CMTime? = t.firstStreamTime != nil ? CMTimeAdd(t.lastPTS, t.lastDuration) : nil
        let role = self.role
        let url = t.writer.url
        let written = t.writer.videoFramesWritten
        let firstHost = t.firstHostNanos
        let completion = t.completion
        let timecode = t.firstTimecode.map { TimecodeRange(start: $0, end: t.lastTimecode ?? $0, base: t.timecodeBase) }
        t.writer.finish(endTime: endTime) { error in
            let result = ChannelTakeResult(role: role, url: url, firstFrameHostNanos: firstHost,
                                           framesWritten: written, error: error?.localizedDescription,
                                           timecode: timecode)
            DispatchQueue.main.async {
                self.isRecording = false
                completion(result)
            }
        }
    }

    // MARK: - Camera timecode and REC (queue)

    /// How the camera's REC is read (per project setting).
    func setRecDetection(_ detection: CameraRecDetection) {
        recDetection.withLock { $0 = detection }
    }

    /// Writes the SDI data log (timecode, flags and every ancillary packet that changes) to `url`; nil stops it.
    func setSDILog(_ url: URL?) {
        source?.captureAncillary = url != nil
        let name = role.rawValue
        queue.async {
            self.sdiLog?.close()
            self.sdiLog = url.flatMap { SDIDataLog(url: $0, camera: name) }
        }
        signal.sdiLog = url
    }

    private func readCamera(_ frame: CapturedFrame) {
        let now = HostClock.nowNanos
        let detection = recDetection.withLock { $0 }
        var raw = CameraRecState.unknown
        var fromFlag = false
        if let tc = frame.timecode {
            if let last = qTimecode {
                if tc != last { qTCMoving += 1; qTCStill = 0 } else { qTCStill += 1; qTCMoving = 0 }
            }
            qTimecode = tc
            qTimecodeNanos = frame.hostTimeNanos
            qFrameDuration = frame.duration
        } else if now - qTimecodeNanos > 1_000_000_000 {
            qTimecode = nil
            qTCMoving = 0
            qTCStill = 0
        }
        if detection != .off {
            if let flag = frame.cameraRecording {
                raw = flag ? .recording : .stopped
                fromFlag = true
            } else if detection == .recRun, frame.timecode != nil {
                raw = qTCMoving >= 2 ? .recording : (qTCStill >= 2 ? .stopped : qCamRec)
            }
        }
        // A change counts after 3 frames in a row (one odd frame does not start / stop anything).
        if raw == qCandidate { qCandidateFrames += 1 } else { qCandidate = raw; qCandidateFrames = 1 }
        var changed = false
        if qCandidate != qCamRec && qCandidateFrames >= 3 {
            qCamRec = qCandidate
            changed = true
        }

        let tc = qTimecode
        let host = qTimecodeNanos
        let duration = qFrameDuration.seconds
        let rec = qCamRec
        let didChange = changed
        DispatchQueue.main.async {
            let info = self.signal
            if info.timecode != tc { info.timecode = tc }
            info.timecodeHostNanos = host
            if info.frameDuration != duration { info.frameDuration = duration }
            if info.recFromFlag != fromFlag { info.recFromFlag = fromFlag }
            if info.cameraRec != rec { info.cameraRec = rec }
            if didChange { self.onCameraRecChange?(rec) }
        }
        if changed { sdiLog?.note("Camera REC detected: \(rec == .recording ? "RECORDING" : rec == .stopped ? "STOPPED" : "unknown")\(fromFlag ? " (record flag)" : " (timecode)")") }
    }

    private func publishIfNeeded() {
        let now = HostClock.nowNanos
        guard now - lastPublishNanos > 100_000_000 else { return }  // 10 Hz UI updates
        lastPublishNanos = now
        qStats.writeBacklog = take != nil ? backlogPeak : 0
        backlogPeak = 0
        let s = qStats
        let signal = qHasSignal
        let db: Float = qPeak > 0 ? 20 * log10(qPeak) : -120
        qPeak = 0
        DispatchQueue.main.async {
            if self.stats != s { self.stats = s }
            if self.hasSignal != signal { self.hasSignal = signal }
            self.audioLevelDB = db
        }
    }

    /// Peak of the first two channels, normalized 0…1.
    private static func peak(of audio: CapturedAudio) -> Float {
        let channels = max(1, audio.channels)
        let used = min(2, channels)
        var peak: Int64 = 0
        audio.data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int32.self)
            let frames = min(audio.sampleFrames, samples.count / channels)
            var i = 0
            while i < frames {
                for c in 0..<used {
                    let v = abs(Int64(samples[i * channels + c]))
                    if v > peak { peak = v }
                }
                i += 1
            }
        }
        return Float(Double(peak) / Double(Int32.max))
    }
}
