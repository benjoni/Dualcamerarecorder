//
//  CameraSetup.swift
//  DualCamRecorder
//
//  Camera setup of one camera for a take: lens, stop, focus distance, height, tilt, …
//  Free text (the crew writes the units they use); a bare number gets the usual unit (5600 → 5600K). Stored in the slate (setupA / setupB),
//  so it goes into C###_SLATE.JSON, the movie metadata, CLIPLOG.CSV and the PDF report.
//

import Foundation

struct CameraSetup: Codable, Hashable {
    var lens = ""          // "Cooke S4 32mm"
    var stop = ""          // "T2.8"
    var focus = ""         // focus / subject distance, "3.2 m"
    var height = ""        // lens height, "1.40 m"
    var tilt = ""          // "−5°"
    var filter = ""        // "ND 0.6"
    var iso = ""           // "800"
    var shutter = ""       // "180°" or "1/50"
    var whiteBalance = ""  // "5600K"

    /// Fields in display order: (key path, title, placeholder).
    static let fields: [(WritableKeyPath<CameraSetup, String>, String, String)] = [
        (\.lens, "Lens", "32mm"),
        (\.stop, "Stop", "T2.8"),
        (\.focus, "Distance", "3.2 m"),
        (\.height, "Height", "1.40 m"),
        (\.tilt, "Tilt", "−5°"),
        (\.filter, "Filter", "ND 0.6"),
        (\.iso, "ISO", "800"),
        (\.shutter, "Shutter", "180°"),
        (\.whiteBalance, "WB", "5600K"),
    ]

    /// Unit added to a bare number: "5600" → "5600K", "2.8" → "T2.8". Text with its own unit ("AWB", "1/50", "10 ft") stays.
    static func completed(_ value: String, field: WritableKeyPath<CameraSetup, String>) -> String {
        let text = value.trimmingCharacters(in: .whitespaces)
        guard text.range(of: #"^[+\-−]?[0-9]+([.,][0-9]+)?$"#, options: .regularExpression) != nil else { return value }
        switch field {
        case \.lens: return text + "mm"
        case \.stop: return "T" + text
        case \.focus, \.height: return text + " m"
        case \.tilt, \.shutter: return text + "°"
        case \.whiteBalance: return text + "K"
        default: return value
        }
    }

    /// Every field with its unit completed.
    var completed: CameraSetup {
        var setup = self
        for field in Self.fields { setup[keyPath: field.0] = Self.completed(setup[keyPath: field.0], field: field.0) }
        return setup
    }

    var isEmpty: Bool { Self.fields.allSatisfy { self[keyPath: $0.0].trimmingCharacters(in: .whitespaces).isEmpty } }

    /// "Lens 32mm · Stop T2.8 · Distance 3.2 m · Height 1.40 m · Tilt −5°" (only filled fields).
    var summary: String {
        Self.fields.compactMap { field in
            let value = self[keyPath: field.0].trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : "\(field.1) \(value)"
        }
        .joined(separator: " · ")
    }
}

extension CameraSetup {
    /// Tolerant decoding: fields added later get their defaults.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lens = try c.decodeIfPresent(String.self, forKey: .lens) ?? ""
        stop = try c.decodeIfPresent(String.self, forKey: .stop) ?? ""
        focus = try c.decodeIfPresent(String.self, forKey: .focus) ?? ""
        height = try c.decodeIfPresent(String.self, forKey: .height) ?? ""
        tilt = try c.decodeIfPresent(String.self, forKey: .tilt) ?? ""
        filter = try c.decodeIfPresent(String.self, forKey: .filter) ?? ""
        iso = try c.decodeIfPresent(String.self, forKey: .iso) ?? ""
        shutter = try c.decodeIfPresent(String.self, forKey: .shutter) ?? ""
        whiteBalance = try c.decodeIfPresent(String.self, forKey: .whiteBalance) ?? ""
    }
}
