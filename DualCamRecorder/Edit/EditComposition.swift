//
//  EditComposition.swift
//  DualCamRecorder
//
//  Timeline → AVMutableComposition (pieces of the original files, nothing is copied),
//  the player of the Edit tab and the MOV export for the director.
//

import AVFoundation
import AppKit
import QuartzCore

enum EditComposition {
    struct Piece {
        let segment: TimelineSegment
        let start: Double
        let duration: Double
    }

    struct Built {
        let composition: AVMutableComposition
        let pieces: [Piece]
        let fps: Double
    }

    /// Joins the pieces one after another. Pieces whose file is missing are left out.
    static func build(segments: [TimelineSegment], folder: URL) async -> Built? {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        var cursor = CMTime.zero
        var pieces: [Piece] = []
        var transformSet = false
        var fps = 25.0

        for segment in segments {
            guard let file = segment.file else { continue }
            let asset = AVURLAsset(url: folder.appendingPathComponent(file))
            guard let sourceVideo = try? await asset.loadTracks(withMediaType: .video).first,
                  let assetDuration = try? await asset.load(.duration) else { continue }
            let start = CMTime(seconds: segment.inPoint, preferredTimescale: 60000)
            let end = CMTimeMinimum(CMTime(seconds: segment.outPoint, preferredTimescale: 60000), assetDuration)
            guard end > start else { continue }
            let range = CMTimeRange(start: start, end: end)
            do {
                try videoTrack.insertTimeRange(range, of: sourceVideo, at: cursor)
            } catch { continue }
            if !transformSet, let t = try? await sourceVideo.load(.preferredTransform) {
                videoTrack.preferredTransform = t
                transformSet = true
                if let rate = try? await sourceVideo.load(.nominalFrameRate), rate > 0 { fps = Double(rate) }
            }
            if let sourceAudio = try? await asset.loadTracks(withMediaType: .audio).first,
               (try? audioTrack.insertTimeRange(range, of: sourceAudio, at: cursor)) != nil {
            } else {
                audioTrack.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: range.duration))
            }
            pieces.append(Piece(segment: segment, start: cursor.seconds, duration: range.duration.seconds))
            cursor = CMTimeAdd(cursor, range.duration)
        }
        return pieces.isEmpty ? nil : Built(composition: composition, pieces: pieces, fps: fps)
    }

    // MARK: - Export for the director (H.264 1080p MOV)

    enum ExportError: LocalizedError {
        case nothingToExport, cannotExport, failed(String)
        var errorDescription: String? {
            switch self {
            case .nothingToExport: return "The timeline is empty or its files are missing."
            case .cannotExport: return "This timeline cannot be exported as H.264 1080p."
            case .failed(let message): return message
            }
        }
    }

    /// Renders the timeline; with `burnIn` every piece shows its clip / scene / shot / take and camera in the corner.
    static func export(segments: [TimelineSegment], folder: URL, to url: URL, burnIn: Bool,
                       progress: @escaping (Float) -> Void) async throws {
        guard let built = await build(segments: segments, folder: folder) else { throw ExportError.nothingToExport }
        guard let session = AVAssetExportSession(asset: built.composition, presetName: AVAssetExportPreset1920x1080) else {
            throw ExportError.cannotExport
        }
        session.outputURL = url
        session.outputFileType = .mov
        if burnIn, let videoComposition = try? await AVMutableVideoComposition.videoComposition(withPropertiesOf: built.composition) {
            addLabels(to: videoComposition, pieces: built.pieces)
            session.videoComposition = videoComposition
        }
        try? FileManager.default.removeItem(at: url)

        let poll = Task { @MainActor in
            while !Task.isCancelled {
                progress(session.progress)
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        defer { poll.cancel() }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { done.resume() }
        }
        switch session.status {
        case .completed: return
        case .cancelled: throw CancellationError()
        default: throw ExportError.failed(session.error?.localizedDescription ?? "Export failed.")
        }
    }

    /// Text in the bottom left corner, shown only while its piece plays.
    private static func addLabels(to videoComposition: AVMutableVideoComposition, pieces: [Piece]) {
        let size = videoComposition.renderSize
        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: size)
        let video = CALayer()
        video.frame = parent.frame
        parent.addSublayer(video)

        let fontSize = max(18, size.height / 30)
        for piece in pieces {
            // Text drawn into an image – CATextLayer glyphs are not rendered by the export.
            let text = "\(piece.segment.label) · Camera \(piece.segment.cameraName)"
            guard let image = labelImage(text, fontSize: fontSize, maxWidth: size.width - 2 * fontSize) else { continue }
            let label = CALayer()
            label.contents = image
            label.frame = CGRect(x: fontSize, y: fontSize, width: CGFloat(image.width), height: CGFloat(image.height))
            label.opacity = 0
            let show = CABasicAnimation(keyPath: "opacity")
            show.fromValue = 1
            show.toValue = 1
            show.beginTime = AVCoreAnimationBeginTimeAtZero + piece.start
            show.duration = piece.duration
            show.isRemovedOnCompletion = true
            label.add(show, forKey: "show")
            parent.addSublayer(label)
        }
        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: video, in: parent)
    }

    /// White bold text on a dark rounded box.
    private static func labelImage(_ text: String, fontSize: CGFloat, maxWidth: CGFloat) -> CGImage? {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: fontSize),
                                                         .foregroundColor: NSColor.white]
        let string = NSAttributedString(string: text, attributes: attributes)
        let padding = fontSize * 0.4
        let textSize = string.size()
        let width = Int(min(maxWidth, textSize.width + 2 * padding).rounded(.up))
        let height = Int((textSize.height + padding).rounded(.up))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(NSColor.black.withAlphaComponent(0.6).cgColor)
        context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height),
                               cornerWidth: padding, cornerHeight: padding, transform: nil))
        context.fillPath()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        string.draw(at: CGPoint(x: padding, y: padding / 2))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}

/// Player of the Edit tab: plays the whole timeline as one movie.
@MainActor
final class EditPlayer: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var fps: Double = 25
    /// Pieces as they are in the loaded movie (start / length).
    @Published private(set) var pieces: [EditComposition.Piece] = []
    private var timeObserver: Any?
    private var buildGeneration = 0

    init() {
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
                self.isPlaying = self.player.rate != 0
            }
        }
    }

    /// Re-builds the movie after the timeline changed, keeping the position.
    func reload(segments: [TimelineSegment], folder: URL?) async {
        buildGeneration += 1
        let generation = buildGeneration
        guard let folder, !segments.isEmpty else {
            player.replaceCurrentItem(with: nil)
            pieces = []
            duration = 0
            currentTime = 0
            isPlaying = false
            return
        }
        let position = currentTime
        let wasPlaying = isPlaying
        let built = await EditComposition.build(segments: segments, folder: folder)
        guard generation == buildGeneration else { return }   // a newer change is being loaded
        guard let built else {
            player.replaceCurrentItem(with: nil)
            pieces = []
            duration = 0
            return
        }
        let item = AVPlayerItem(asset: built.composition)
        player.replaceCurrentItem(with: item)
        pieces = built.pieces
        fps = built.fps
        duration = built.composition.duration.seconds
        seek(to: min(position, max(0, duration - 0.04)))
        if wasPlaying { player.play() }
    }

    func togglePlay() {
        if player.rate != 0 {
            player.pause()
        } else {
            if currentTime >= duration - 0.05 { seek(to: 0) }
            player.play()
        }
        isPlaying = player.rate != 0
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func seek(to seconds: Double) {
        let t = CMTime(seconds: max(0, seconds), preferredTimescale: 60000)
        currentTime = t.seconds
        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// One frame back / forward.
    func step(_ frames: Int) {
        pause()
        seek(to: min(duration, max(0, currentTime + Double(frames) / fps)))
    }

    func timecode(_ seconds: Double) -> String {
        let nominal = max(1, Int(fps.rounded()))
        let totalFrames = Int((max(0, seconds) * fps).rounded())
        let s = totalFrames / nominal
        return String(format: "%02d:%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60, totalFrames % nominal)
    }

    /// Piece that is playing at `time`.
    func pieceIndex(at time: Double) -> Int? {
        pieces.lastIndex { time >= $0.start - 0.001 }
    }
}
