//
//  EditTimeline.swift
//  DualCamRecorder
//
//  Simple edit for the director: pieces of clips (always one camera) in a row. A project has several
//  sequences (one passage cut, then New and another one …); the timeline shows the selected one.
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

/// One cut passage.
struct EditSequence: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var segments: [TimelineSegment] = []

    var duration: Double { segments.reduce(0) { $0 + $1.duration } }
}

final class EditTimeline: ObservableObject {
    /// Pieces of the selected sequence.
    @Published private(set) var segments: [TimelineSegment] = []
    /// All sequences of the project (the selected one is updated whenever the timeline is saved).
    @Published private(set) var sequences: [EditSequence] = []
    @Published private(set) var currentID: EditSequence.ID?
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
        var loaded: [EditSequence] = []
        var current: EditSequence.ID?
        if let folder,
           let data = try? Data(contentsOf: folder.appendingPathComponent(Self.fileName)),
           let saved = try? JSONDecoder().decode(SavedEdit.self, from: data) {
            loaded = saved.sequences ?? []
            current = saved.current
            // EDIT.JSON of version 1: one timeline.
            if loaded.isEmpty, let old = saved.segments, !old.isEmpty {
                loaded = [EditSequence(name: "Sequence 1", segments: old)]
            }
        }
        if loaded.isEmpty { loaded = [EditSequence(name: "Sequence 1")] }
        sequences = loaded
        let selected = loaded.first { $0.id == current } ?? loaded[0]
        currentID = selected.id
        segments = selected.segments
    }

    private func save() {
        syncCurrent()
        guard let folder else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(SavedEdit(sequences: sequences, current: currentID)) else { return }
        try? data.write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }

    /// Timeline → its sequence in the list.
    private func syncCurrent() {
        guard let i = sequences.firstIndex(where: { $0.id == currentID }), sequences[i].segments != segments else { return }
        sequences[i].segments = segments
    }

    private struct SavedEdit: Codable {
        var version = 2
        var sequences: [EditSequence]?
        var current: EditSequence.ID?
        /// Version 1 (one timeline) – read only.
        var segments: [TimelineSegment]?
    }

    // MARK: - Sequences

    var currentSequence: EditSequence? { sequences.first { $0.id == currentID } }

    /// Shows another sequence on the timeline (Undo starts again).
    func select(_ id: EditSequence.ID) {
        guard id != currentID, let next = sequences.first(where: { $0.id == id }) else { return }
        syncCurrent()
        currentID = id
        segments = next.segments
        history = []
        canUndo = false
        save()
    }

    /// Empty sequence "Sequence N", selected.
    func newSequence() {
        syncCurrent()
        let sequence = EditSequence(name: nextName("Sequence"))
        sequences.append(sequence)
        select(sequence.id)
    }

    /// Copy of a sequence ("… copy"), selected.
    func duplicate(_ id: EditSequence.ID) {
        syncCurrent()
        guard let i = sequences.firstIndex(where: { $0.id == id }) else { return }
        var copy = sequences[i]
        copy.id = UUID()
        copy.segments = copy.segments.map { var s = $0; s.id = UUID(); return s }
        copy.name = nextName(copy.name + " copy")
        sequences.insert(copy, at: i + 1)
        select(copy.id)
    }

    func rename(_ id: EditSequence.ID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = sequences.firstIndex(where: { $0.id == id }), sequences[i].name != trimmed else { return }
        sequences[i].name = trimmed
        save()
    }

    /// Deletes a sequence (the last one is only emptied).
    func delete(_ id: EditSequence.ID) {
        syncCurrent()
        guard let i = sequences.firstIndex(where: { $0.id == id }) else { return }
        if sequences.count == 1 {
            sequences[0].segments = []
            segments = []
            history = []
            canUndo = false
            save()
            return
        }
        sequences.remove(at: i)
        if id == currentID {
            let next = sequences[min(i, sequences.count - 1)]
            currentID = next.id
            segments = next.segments
            history = []
            canUndo = false
        }
        save()
    }

    /// "Sequence 3" – the first number not used yet (or the name itself when free).
    private func nextName(_ base: String) -> String {
        let used = Set(sequences.map(\.name))
        if base != "Sequence", !used.contains(base) { return base }
        var n = base == "Sequence" ? sequences.count + 1 : 2
        while used.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
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
