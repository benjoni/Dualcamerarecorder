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
    var shootingDay = ""     // shooting day (e.g. "3" or "D03")
    var director = ""        // director
    var cameraOperator = ""  // camera operator (DoP)
    var scene = ""           // scene
    var shot = ""            // shot
    var take = 1             // take
    var location: Location = .none
    var timeOfDay: TimeOfDay = .none
    var mos = false          // without sound
    var note = ""            // note
    var good = false         // good (circled) take
    /// Rehearsal: recorded only by the app, the cameras did not record (no take number, no camera clip).
    var rehearsal = false
    var recordedAt: Date?    // set at REC
    /// Clip name/ID in each camera's own (internal) recording, e.g. "A001C0023" (any length).
    /// Its last number goes up by 1 after every take. Empty = that camera did not record this take.
    var cameraClipA = ""
    var cameraClipB = ""
    /// Number of the memory card in each camera, e.g. "A001" (stays from take to take; empty = not filled in).
    var cardA = ""
    var cardB = ""
    /// Lens / stop / distance / height / tilt … of each camera (empty = not filled in).
    var setupA = CameraSetup()
    var setupB = CameraSetup()
    /// Camera timecode (TC IN – TC OUT) of each recorded file, from the SDI signal (nil: none).
    var timecodeA: TimecodeRange?
    var timecodeB: TimecodeRange?

    func timecode(_ role: CameraRole) -> TimecodeRange? { role == .a ? timecodeA : timecodeB }

    func cameraClip(_ role: CameraRole) -> String { role == .a ? cameraClipA : cameraClipB }
    func card(_ role: CameraRole) -> String { role == .a ? cardA : cardB }
    func setup(_ role: CameraRole) -> CameraSetup { role == .a ? setupA : setupB }

    /// "Day 3 · Scene 12 · Shot 3 · Take 2"
    var shortLabel: String {
        shootingDay.isEmpty ? sceneShotTake : "Day \(shootingDay) · " + sceneShotTake
    }

    /// "Scene 12 · Shot 3 · Take 2"
    var sceneShotTake: String {
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
        if !shootingDay.isEmpty { lines.append("Shooting day: \(shootingDay)") }
        lines.append(shortLabel)
        let flags = [location.rawValue, timeOfDay.rawValue, mos ? "MOS" : ""].filter { !$0.isEmpty }
        if !flags.isEmpty { lines.append(flags.joined(separator: " · ")) }
        if !director.isEmpty { lines.append("Director: \(director)") }
        if !cameraOperator.isEmpty { lines.append("DoP: \(cameraOperator)") }
        if rehearsal { lines.append("Rehearsal") }
        if good { lines.append("Good take") }
        var clips: [String] = []
        if !cameraClipA.isEmpty { clips.append("A " + cameraClipA) }
        if !cameraClipB.isEmpty { clips.append("B " + cameraClipB) }
        if !clips.isEmpty { lines.append("Camera clip: " + clips.joined(separator: " / ")) }
        let cards = [cardA.isEmpty ? nil : "A " + cardA, cardB.isEmpty ? nil : "B " + cardB].compactMap { $0 }
        if !cards.isEmpty { lines.append("Card: " + cards.joined(separator: " / ")) }
        if !setupA.isEmpty { lines.append("Camera A settings: " + setupA.summary) }
        if !setupB.isEmpty { lines.append("Camera B settings: " + setupB.summary) }
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
        var items = [
            item(.quickTimeMetadataTitle, title),
            item(.quickTimeMetadataDescription, longDescription + "\nFile: " + TakeNaming.fileName(take: takeNumber, role: camera, slate: self, names: names)),
            item(.quickTimeMetadataComment, note),
            item(.quickTimeMetadataDirector, director),
            item(.quickTimeMetadataCameraIdentifier, names.name(camera)),
            item(.quickTimeMetadataCreationDate, date),
        ].compactMap { $0 }
        // Camera's own clip number – a custom key scripts can read
        // (e.g. `exiftool -Keys:All file.MOV` or `ffprobe -show_format`).
        let cameraClip = self.cameraClip(camera)
        if !cameraClip.isEmpty {
            let custom = AVMutableMetadataItem()
            custom.keySpace = .quickTimeMetadata
            custom.key = "sk.dualcam.camera-clip" as NSString
            custom.value = cameraClip as NSString
            items.append(custom)
            if let comment = item(.quickTimeMetadataInformation, "Camera clip " + cameraClip) {
                items.append(comment)
            }
        }
        let card = self.card(camera)
        if !card.isEmpty {
            let custom = AVMutableMetadataItem()
            custom.keySpace = .quickTimeMetadata
            custom.key = "sk.dualcam.camera-card" as NSString
            custom.value = card as NSString
            items.append(custom)
        }
        let setup = self.setup(camera)
        if !setup.isEmpty {
            let custom = AVMutableMetadataItem()
            custom.keySpace = .quickTimeMetadata
            custom.key = "sk.dualcam.camera-setup" as NSString
            custom.value = setup.summary as NSString
            items.append(custom)
        }
        return items
    }
}

extension SlateInfo {
    /// Tolerant decoding: fields missing in slates saved by older versions get their defaults.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        production = try c.decodeIfPresent(String.self, forKey: .production) ?? production
        shootingDay = try c.decodeIfPresent(String.self, forKey: .shootingDay) ?? shootingDay
        director = try c.decodeIfPresent(String.self, forKey: .director) ?? director
        cameraOperator = try c.decodeIfPresent(String.self, forKey: .cameraOperator) ?? cameraOperator
        scene = try c.decodeIfPresent(String.self, forKey: .scene) ?? scene
        shot = try c.decodeIfPresent(String.self, forKey: .shot) ?? shot
        take = try c.decodeIfPresent(Int.self, forKey: .take) ?? take
        location = try c.decodeIfPresent(Location.self, forKey: .location) ?? location
        timeOfDay = try c.decodeIfPresent(TimeOfDay.self, forKey: .timeOfDay) ?? timeOfDay
        mos = try c.decodeIfPresent(Bool.self, forKey: .mos) ?? mos
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? note
        good = try c.decodeIfPresent(Bool.self, forKey: .good) ?? good
        rehearsal = (try? c.decodeIfPresent(Bool.self, forKey: .rehearsal)) ?? rehearsal
        recordedAt = try c.decodeIfPresent(Date.self, forKey: .recordedAt)
        cameraClipA = Self.decodeClip(c, .cameraClipA)
        cameraClipB = Self.decodeClip(c, .cameraClipB)
        cardA = (try? c.decodeIfPresent(String.self, forKey: .cardA)) ?? ""
        cardB = (try? c.decodeIfPresent(String.self, forKey: .cardB)) ?? ""
        setupA = try c.decodeIfPresent(CameraSetup.self, forKey: .setupA) ?? setupA
        setupB = try c.decodeIfPresent(CameraSetup.self, forKey: .setupB) ?? setupB
        timecodeA = try? c.decodeIfPresent(TimecodeRange.self, forKey: .timecodeA)
        timecodeB = try? c.decodeIfPresent(TimecodeRange.self, forKey: .timecodeB)
    }
}

extension SlateInfo {
    /// Camera clip as text; numbers written by an earlier version become "0023" (0 → empty).
    private static func decodeClip(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String {
        if let s = try? c.decodeIfPresent(String.self, forKey: key) { return s }
        if let n = try? c.decodeIfPresent(Int.self, forKey: key) { return n > 0 ? String(format: "%04d", n) : "" }
        return ""
    }
}

/// Camera clip IDs like "A001C0023": the last number is counted up/down, keeping its zero padding.
enum CameraClipID {
    static func next(_ id: String) -> String { step(id, by: 1) }
    static func previous(_ id: String) -> String { step(id, by: -1) }

    static func step(_ id: String, by delta: Int) -> String {
        let chars = Array(id)
        guard let lastDigit = chars.lastIndex(where: { $0.isASCII && $0.isNumber }) else { return id }
        var start = lastDigit
        while start > 0, chars[start - 1].isASCII, chars[start - 1].isNumber { start -= 1 }
        let digits = String(chars[start...lastDigit])
        guard let value = Int(digits) else { return id }
        let newValue = max(0, value + delta)
        let padded = String(repeating: "0", count: max(0, digits.count - String(newValue).count)) + String(newValue)
        return String(chars[..<start]) + padded + String(chars[(lastDigit + 1)...])
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
