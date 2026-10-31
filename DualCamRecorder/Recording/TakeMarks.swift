//
//  TakeMarks.swift
//  DualCamRecorder
//
//  IN / OUT points of a take, stored next to the movies as Take_001_marks.json.
//  Times are seconds from the start of the take (= first frame of both CamA and CamB files).
//

import Foundation

struct TakeMarks: Codable, Hashable {
    var inPoint: Double?
    var outPoint: Double?

    var isEmpty: Bool { inPoint == nil && outPoint == nil }

    /// Sets IN; drops OUT if it would end up before IN.
    mutating func setIn(_ t: Double) {
        inPoint = max(0, t)
        if let out = outPoint, out <= inPoint! { outPoint = nil }
    }

    /// Sets OUT; returns false if OUT would be before IN.
    @discardableResult
    mutating func setOut(_ t: Double) -> Bool {
        if let i = inPoint, t <= i { return false }
        outPoint = max(0, t)
        return true
    }
}

enum TakeMarksStore {
    static func url(folder: URL, take: Int) -> URL {
        folder.appendingPathComponent(String(format: "Take_%03d_marks.json", take))
    }

    static func load(folder: URL, take: Int) -> TakeMarks? {
        guard let data = try? Data(contentsOf: url(folder: folder, take: take)) else { return nil }
        return try? JSONDecoder().decode(TakeMarks.self, from: data)
    }

    /// Writes the marks (or removes the file when empty).
    static func save(_ marks: TakeMarks, folder: URL, take: Int) throws {
        let target = url(folder: folder, take: take)
        if marks.isEmpty {
            try? FileManager.default.removeItem(at: target)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(marks).write(to: target, options: .atomic)
    }
}
