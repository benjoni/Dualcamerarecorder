//
//  TakeMarks.swift
//  DualCamRecorder
//
//  IN / OUT ranges of a take, stored next to the movies as C001_MARKS.JSON.
//  Times are seconds from the start of the take (= first frame of both CamA and CamB files).
//  IN starts a range, OUT closes it, the next IN starts another one. Older files with one IN / OUT
//  are read as one range; the first range is also written the old way for older app versions.
//

import Foundation

/// One IN → OUT range (OUT missing: to the end of the take).
struct MarkRange: Codable, Hashable {
    var inPoint: Double
    var outPoint: Double?
}

struct TakeMarks: Codable, Hashable {
    /// Ranges in the order they were set; only the last one can still be without OUT.
    private(set) var ranges: [MarkRange] = []

    init() {}

    var isEmpty: Bool { ranges.isEmpty }

    /// Start of the earliest range (where a clip is cued).
    var firstInPoint: Double? { ranges.map(\.inPoint).min() }

    /// IN / OUT of the range being set (the last one).
    var inPoint: Double? { ranges.last?.inPoint }
    var outPoint: Double? { ranges.last?.outPoint }

    /// IN: moves the IN of a range still without OUT, else starts a new range.
    mutating func setIn(_ t: Double) {
        let t = max(0, t)
        if let last = ranges.indices.last, ranges[last].outPoint == nil {
            ranges[last].inPoint = t
        } else {
            ranges.append(MarkRange(inPoint: t))
        }
    }

    /// OUT: closes the last range (or moves its OUT); without any IN the range starts at 0.
    /// Returns false if OUT would be before IN.
    @discardableResult
    mutating func setOut(_ t: Double) -> Bool {
        let t = max(0, t)
        guard let last = ranges.indices.last else {
            guard t > 0 else { return false }
            ranges.append(MarkRange(inPoint: 0, outPoint: t))
            return true
        }
        guard t > ranges[last].inPoint else { return false }
        ranges[last].outPoint = t
        return true
    }

    /// Removes the last range.
    mutating func removeLast() {
        if !ranges.isEmpty { ranges.removeLast() }
    }

    /// All times moved by `delta` seconds (not below 0).
    func shifted(by delta: Double) -> TakeMarks {
        var m = self
        m.ranges = ranges.map { MarkRange(inPoint: max(0, $0.inPoint + delta), outPoint: $0.outPoint.map { max(0, $0 + delta) }) }
        return m
    }

    /// Ranges in time order with OUT filled in (`duration` for a missing OUT); overlapping ones joined.
    func spans(duration: Double) -> [ClosedRange<Double>] {
        let sorted = ranges
            .map { $0.inPoint...max($0.inPoint, $0.outPoint ?? duration) }
            .filter { $0.upperBound > $0.lowerBound }
            .sorted { $0.lowerBound < $1.lowerBound }
        var joined: [ClosedRange<Double>] = []
        for span in sorted {
            if let last = joined.last, span.lowerBound <= last.upperBound {
                joined[joined.count - 1] = last.lowerBound...max(last.upperBound, span.upperBound)
            } else {
                joined.append(span)
            }
        }
        return joined
    }

    /// Length of all ranges together.
    func totalDuration(duration: Double) -> Double {
        spans(duration: duration).reduce(0) { $0 + $1.upperBound - $1.lowerBound }
    }

    // MARK: Codable (older files: one inPoint / outPoint)

    private enum CodingKeys: String, CodingKey { case ranges, inPoint, outPoint }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let ranges = try c.decodeIfPresent([MarkRange].self, forKey: .ranges) {
            self.ranges = ranges
        } else {
            let i = try c.decodeIfPresent(Double.self, forKey: .inPoint)
            let o = try c.decodeIfPresent(Double.self, forKey: .outPoint)
            if i != nil || o != nil { ranges = [MarkRange(inPoint: i ?? 0, outPoint: o)] }
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ranges, forKey: .ranges)
        try c.encodeIfPresent(ranges.first?.inPoint, forKey: .inPoint)
        try c.encodeIfPresent(ranges.first?.outPoint, forKey: .outPoint)
    }
}

enum TakeMarksStore {
    static func url(folder: URL, take: Int) -> URL {
        folder.appendingPathComponent(TakeNaming.sidecarName(take: take, kind: "marks"))
    }

    static func load(folder: URL, take: Int) -> TakeMarks? {
        guard let data = TakeNaming.readSidecar(folder: folder, take: take, kind: "marks") else { return nil }
        return try? JSONDecoder().decode(TakeMarks.self, from: data)
    }

    /// Writes the marks (or removes the file when empty).
    static func save(_ marks: TakeMarks, folder: URL, take: Int) throws {
        let target = url(folder: folder, take: take)
        // Remove older sidecars first (on a case-insensitive disk some are the same file).
        TakeNaming.removeLegacySidecars(folder: folder, take: take, kind: "marks")
        if marks.isEmpty {
            try? FileManager.default.removeItem(at: target)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(marks).write(to: target, options: .atomic)
    }
}
