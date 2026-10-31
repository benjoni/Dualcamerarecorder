//
//  ClipLog.swift
//  DualCamRecorder
//
//  CLIPLOG.CSV in the project folder: one row per recorded movie, so scripts can match our files
//  with the cameras' own internal clips (camera_clip) and the slate.
//  Rebuilt from the C###_SLATE.JSON files after every take and after editing a slate.
//

import Foundation

enum ClipLog {
    static let fileName = "CLIPLOG.CSV"

    static let header = ["clip", "camera", "camera_name", "file", "camera_clip", "shooting_day", "scene", "shot",
                         "take", "good", "mos", "int_ext", "day_night", "recorded_at", "production", "note"]

    /// Rewrites CLIPLOG.CSV for `folder`. Safe to call from any thread.
    static func rebuild(folder: URL, names: CameraNames) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var entries: [(take: Int, role: CameraRole, file: String)] = []
        for file in files {
            if let parsed = TakeNaming.parse(file, names: names) {
                entries.append((parsed.take, parsed.role, file))
            }
        }
        entries.sort { $0.take != $1.take ? $0.take < $1.take : $0.role.rawValue < $1.role.rawValue }

        let iso = ISO8601DateFormatter()
        var slates: [Int: SlateInfo] = [:]
        var lines = [header.joined(separator: ",")]
        for entry in entries {
            if slates[entry.take] == nil, let s = TakeSlateStore.load(folder: folder, take: entry.take) {
                slates[entry.take] = s
            }
            let s = slates[entry.take]
            let cameraClip = s.map { $0.cameraClip(entry.role) } ?? 0
            let row: [String] = [
                String(format: "%03d", entry.take),
                entry.role.rawValue,
                names.name(entry.role),
                entry.file,
                cameraClip > 0 ? String(format: "%04d", cameraClip) : "",
                s?.shootingDay ?? "",
                s?.scene ?? "",
                s?.shot ?? "",
                s.map { String($0.take) } ?? "",
                s?.good == true ? "1" : "0",
                s?.mos == true ? "1" : "0",
                s?.location.rawValue ?? "",
                s?.timeOfDay.rawValue ?? "",
                s?.recordedAt.map { iso.string(from: $0) } ?? "",
                s?.production ?? "",
                s?.note ?? "",
            ]
            lines.append(row.map(csvField).joined(separator: ","))
        }
        let text = lines.joined(separator: "\n") + "\n"
        try? text.data(using: .utf8)?.write(to: folder.appendingPathComponent(fileName), options: .atomic)
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
