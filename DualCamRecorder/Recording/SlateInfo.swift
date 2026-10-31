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
        case none = "", day = "DEŇ", night = "NOC", dusk = "ŠERO"
        var id: String { rawValue }
        var title: String { self == .none ? "—" : rawValue }
    }

    var production = ""      // Projekt / názov filmu
    var director = ""        // Réžia
    var cameraOperator = ""  // Kamera (DoP)
    var scene = ""           // Obraz
    var shot = ""            // Záber
    var take = 1             // Pokus (klapka)
    var roll = ""            // Rola / karta
    var location: Location = .none
    var timeOfDay: TimeOfDay = .none
    var mos = false          // bez zvuku
    var note = ""            // Poznámka
    var good = false         // dobrý pokus (zakrúžkovaný)
    var recordedAt: Date?    // vyplní sa pri REC

    /// "OBRAZ 12 · ZÁBER 3 · POKUS 2"
    var shortLabel: String {
        var parts: [String] = []
        if !scene.isEmpty { parts.append("Obraz \(scene)") }
        if !shot.isEmpty { parts.append("Záber \(shot)") }
        parts.append("Pokus \(take)")
        return parts.joined(separator: " · ")
    }

    /// Multi-line description used in the movie metadata.
    var longDescription: String {
        var lines: [String] = []
        if !production.isEmpty { lines.append("Projekt: \(production)") }
        lines.append(shortLabel)
        if !roll.isEmpty { lines.append("Rola: \(roll)") }
        let flags = [location.rawValue, timeOfDay.rawValue, mos ? "MOS" : ""].filter { !$0.isEmpty }
        if !flags.isEmpty { lines.append(flags.joined(separator: " · ")) }
        if !director.isEmpty { lines.append("Réžia: \(director)") }
        if !cameraOperator.isEmpty { lines.append("Kamera: \(cameraOperator)") }
        if good { lines.append("Dobrý pokus") }
        if !note.isEmpty { lines.append("Poznámka: \(note)") }
        return lines.joined(separator: "\n")
    }

    /// QuickTime metadata for one camera's file.
    func metadataItems(camera: CameraRole, takeNumber: Int) -> [AVMetadataItem] {
        func item(_ id: AVMetadataIdentifier, _ value: String) -> AVMetadataItem? {
            guard !value.isEmpty else { return nil }
            let m = AVMutableMetadataItem()
            m.identifier = id
            m.value = value as NSString
            m.extendedLanguageTag = "und"
            return m
        }
        var title = shortLabel + " · Cam\(camera.rawValue)"
        if !production.isEmpty { title = production + " – " + title }
        let date = ISO8601DateFormatter().string(from: recordedAt ?? Date())
        return [
            item(.quickTimeMetadataTitle, title),
            item(.quickTimeMetadataDescription, longDescription + "\nSúbor: " + TakeNaming.fileName(take: takeNumber, role: camera, slate: self)),
            item(.quickTimeMetadataComment, note),
            item(.quickTimeMetadataDirector, director),
            item(.quickTimeMetadataCameraIdentifier, "Cam\(camera.rawValue)"),
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
