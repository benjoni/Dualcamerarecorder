//
//  EditTimeline.swift
//  DualCamRecorder
//
//  Simple edit for the director: pieces of clips (always one camera) in a row.
//  Saved as EDIT.JSON in the project folder; the recordings themselves are never changed.
//

import Foundation

extension CameraRole: Codable {}

/// One piece of a clip on the timeline.
struct TimelineSegment: Codable, Identifiable, Equatable {
    var id = UUID()
    var take: Int
    var camera: CameraRole
    /// File names in the project folder (the other camera's file lets the piece switch camera later).
    var fileA: String?
    var fileB: String?
    var inPoint: Double
    var outPoint: Double
    /// Length of the whole clip – trimming cannot go past it.
    var clipDuration: Double
    /// "Clip 014 · Day 2 · Scene 23 · Shot 21 · Take 4"
    var label: String

    var file: String? { camera == .a ? fileA : fileB }
    var duration: Double { max(0, outPoint - inPoint) }
    func hasCamera(_ role: CameraRole) -> Bool { (role == .a ? fileA : fileB) != nil }
    /// Camera name the clip was recorded with ("A", "D" …).
    var cameraName: String { file.flatMap { TakeNaming.cameraName(in: $0) } ?? camera.rawValue }
}

final class EditTimeline: ObservableObject {
    @Published private(set) var segments: [TimelineSegment] = []
    @Published private(set) var canUndo = false
    private(set) var folder: URL?
    private var history: [[TimelineSegment]] = []

    static let fileName = "EDIT.JSON"
    /// Shortest piece (a trim never makes it shorter).
    static let minimumLength = 0.2

    var totalDuration: Double { segments.reduce(0) { $0 + $1.duration } }

    /// Start of each piece on the timeline.
    var starts: [Double] {
        var t = 0.0
        return segments.map { s in defer { t += s.duration }; return t }
    }

    func url(for segment: TimelineSegment) -> URL? {
        guard let folder, let file = segment.file else { return nil }
        return folder.appendingPathComponent(file)
    }

    // MARK: - Project

    func load(folder: URL?) {
        self.folder = folder
        history = []
        canUndo = false
        guard let folder,
              let data = try? Data(contentsOf: folder.appendingPathComponent(Self.fileName)),
              let saved = try? JSONDecoder().decode(SavedEdit.self, from: data) else {
            segments = []
            return
        }
        segments = saved.segments
    }

    private func save() {
        guard let folder else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(SavedEdit(segments: segments)) else { return }
        try? data.write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }

    private struct SavedEdit: Codable {
        var version = 1
        var segments: [TimelineSegment]
    }

    // MARK: - Changes (each one can be undone)

    /// Remembers the current state for Undo; call once before a change (or before a drag starts).
    func beginChange() {
        history.append(segments)
        if history.count > 100 { history.removeFirst() }
        canUndo = true
    }

    func undo() {
        guard let last = history.popLast() else { return }
        segments = last
        canUndo = !history.isEmpty
        save()
    }

    func append(_ segment: TimelineSegment) {
        beginChange()
        segments.append(segment)
        save()
    }

    func remove(_ id: TimelineSegment.ID) {
        guard segments.contains(where: { $0.id == id }) else { return }
        beginChange()
        segments.removeAll { $0.id == id }
        save()
    }

    /// Moves a piece to a new position (index in the list without the piece).
    func move(_ id: TimelineSegment.ID, to index: Int, recordUndo: Bool = true) {
        guard let from = segments.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(0, index), segments.count - 1)
        guard target != from else { return }
        if recordUndo { beginChange() }
        let s = segments.remove(at: from)
        segments.insert(s, at: target)
        save()
    }

    func setCamera(_ id: TimelineSegment.ID, _ role: CameraRole) {
        guard let i = segments.firstIndex(where: { $0.id == id }),
              segments[i].camera != role, segments[i].hasCamera(role) else { return }
        beginChange()
        segments[i].camera = role
        save()
    }

    /// New IN / OUT (kept inside the clip and at least `minimumLength` long). No Undo step – call beginChange() first.
    func trim(_ id: TimelineSegment.ID, inPoint: Double? = nil, outPoint: Double? = nil) {
        guard let i = segments.firstIndex(where: { $0.id == id }) else { return }
        var s = segments[i]
        if let inPoint { s.inPoint = min(max(0, inPoint), s.outPoint - Self.minimumLength) }
        if let outPoint { s.outPoint = max(min(s.clipDuration, outPoint), s.inPoint + Self.minimumLength) }
        guard s != segments[i] else { return }
        segments[i] = s
    }

    /// Writes EDIT.JSON after a drag has finished.
    func commit() { save() }
}
