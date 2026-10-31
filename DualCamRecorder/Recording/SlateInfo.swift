//
//  SlateInfo.swift
//  DualCamRecorder
//
//  Slate (clapperboard) data: production, scene, shot, take, … Stored per take as
//  C###_SLATE.JSON next to the movies and embedded as QuickTime metadata in both .mov files.
//

import Foundation
import AVFoundation

struct SlateInfo: Codable, Hashable {
    enum Location: String, Codable, CaseIterable, Identifiable {
        case none = "", interior = "INT", exterior = "EXT", intExt = "INT/EXT"
        var id: String { rawValue }
        var title: String { self == .none ? "—" : rawValue }
    }

    enum TimeOfDay: String, Codable, CaseIterable, Identifiable {
        case none = "", day = "DAY", night = "NIGHT", dusk = "DUSK"
        var id: String { rawValue }
        var title: String { self == .none ? "—" : rawValue }

        /// Also accepts the Slovak values written by earlier versions (DEŇ / NOC / ŠERO).
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            switch raw {
            case "DEŇ": self = .day
            case "NOC": self = .night
            case "ŠERO": self = .dusk
            default: self = TimeOfDay(rawValue: raw) ?? .none
            }
        }
    }

    var production = ""      // production / film title
    var director = ""        // director
    var cameraOperator = ""  // camera operator (DoP)
    var scene = ""           // scene
    var shot = ""            // shot
    var take = 1             // take
    var roll = ""            // roll / card
    var location: Location = .none
    var timeOfDay: TimeOfDay = .none
    var mos = false          // without sound
    var note = ""            // note
    var good = false         // good (circled) take
    var recordedAt: Date?    // set at REC

    /// "Scene 12 · Shot 3 · Take 2"
    var shortLabel: String {
        var parts: [String] = []
        if !scene.isEmpty { parts.append("Scene \(scene)") }
        if !shot.isEmpty { parts.append("Shot \(shot)") }
        parts.append("Take \(take)")
        return parts.joined(separator: " · ")
    }

    /// Multi-line description used in the movie metadata.
    var longDescription: String {
        var lines: [String] = []
        if !production.isEmpty { lines.append("Production: \(production)") }
        lines.append(shortLabel)
        if !roll.isEmpty { lines.append("Roll: \(roll)") }
        let flags = [location.rawValue, timeOfDay.rawValue, mos ? "MOS" : ""].filter { !$0.isEmpty }
        if !flags.isEmpty { lines.append(flags.joined(separator: " · ")) }
        if !director.isEmpty { lines.append("Director: \(director)") }
        if !cameraOperator.isEmpty { lines.append("DoP: \(cameraOperator)") }
        if good { lines.append("Good take") }
        if !note.isEmpty { lines.append("Note: \(note)") }
        return lines.joined(separator: "\n")
    }

    /// QuickTime metadata for one camera's file.
    func metadataItems(camera: CameraRole, takeNumber: Int, names: CameraNames) -> [AVMetadataItem] {
        func item(_ id: AVMetadataIdentifier, _ value: String) -> AVMetadataItem? {
            guard !value.isEmpty else { return nil }
            let m = AVMutableMetadataItem()
            m.identifier = id
            m.value = value as NSString
            m.extendedLanguageTag = "und"
            return m
        }
        var title = shortLabel + " · " + names.name(camera)
        if !production.isEmpty { title = production + " – " + title }
        let date = ISO8601DateFormatter().string(from: recordedAt ?? Date())
        return [
            item(.quickTimeMetadataTitle, title),
            item(.quickTimeMetadataDescription, longDescription + "\nFile: " + TakeNaming.fileName(take: takeNumber, role: camera, slate: self, names: names)),
            item(.quickTimeMetadataComment, note),
            item(.quickTimeMetadataDirector, director),
            item(.quickTimeMetadataCameraIdentifier, names.name(camera)),
            item(.quickTimeMetadataCreationDate, date),
        ].compactMap { $0 }
    }
}

enum TakeSlateStore {
    static func url(folder: URL, take: Int) -> URL {
        folder.appendingPathComponent(TakeNaming.sidecarName(take: take, kind: "slate"))
    }

    static func load(folder: URL, take: Int) -> SlateInfo? {
        guard let data = TakeNaming.readSidecar(folder: folder, take: take, kind: "slate") else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SlateInfo.self, from: data)
    }

    static func save(_ slate: SlateInfo, folder: URL, take: Int) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(slate)
        TakeNaming.removeLegacySidecars(folder: folder, take: take, kind: "slate")
        try data.write(to: url(folder: folder, take: take), options: .atomic)
    }
}
