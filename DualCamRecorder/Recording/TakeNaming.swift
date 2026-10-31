//
//  TakeNaming.swift
//  DualCamRecorder
//
//  Movie names – all upper case, camera name + clip number first:
//      A007_S12_SH3B_T04.MOV     A / B = camera name (configurable, e.g. RONIN1 → RONIN1_007_…)
//      B007_S12_SH3B_T04.MOV     007 = running clip number (shared by both cameras of one take)
//                                S = scene, SH = shot, T = take (2 digits)
//  Sidecars (shared by A and B): C007_MARKS.JSON, C007_SLATE.JSON.
//  S / SH are left out when the slate field is empty.
//  Older names (C007_…_CAMA.MOV, TAKE_007_…_CAMA.MOV, Take_001_CamA.mov) are still recognised.
//

import Foundation

/// Camera names used at the start of the file names.
struct CameraNames: Equatable {
    var a: String
    var b: String

    init(a: String = "A", b: String = "B") {
        var na = TakeNaming.sanitize(a)
        var nb = TakeNaming.sanitize(b)
        if na.isEmpty { na = "A" }
        if nb.isEmpty { nb = "B" }
        if na == nb { nb += "-B" }   // must differ, otherwise A/B could not be told apart
        self.a = na
        self.b = nb
    }

    func name(_ role: CameraRole) -> String { role == .a ? a : b }

    func role(forPrefix prefix: String) -> CameraRole? {
        let p = prefix.uppercased()
        if p == a { return .a }
        if p == b { return .b }
        return nil
    }
}

enum TakeNaming {
    /// Older formats: C007_…_CAMA.MOV, TAKE_007_…_CAMA.MOV, Take_001_CamA.mov.
    private static let legacyRegex = try! NSRegularExpression(pattern: "^(?:C|TAKE_)(\\d{3,})(?:_.*)?_CAM([AB])\\.MOV$",
                                                              options: [.caseInsensitive])
    /// Current format: <CAMERA>[_]<clip>[_…].MOV
    private static let regex = try! NSRegularExpression(pattern: "^([A-Z0-9-]+?)_?(\\d{3,})(?:_.*)?\\.MOV$",
                                                        options: [.caseInsensitive])

    /// "A" + 7 → "A007", "RONIN1" + 7 → "RONIN1_007" (underscore when the name is longer than one letter).
    static func clipPrefix(take: Int, cameraName: String) -> String {
        let number = String(format: "%03d", take)
        return cameraName.count == 1 ? cameraName + number : cameraName + "_" + number
    }

    static func fileName(take: Int, role: CameraRole, slate: SlateInfo? = nil, names: CameraNames = CameraNames()) -> String {
        var parts = [clipPrefix(take: take, cameraName: names.name(role))]
        if let slate {
            let scene = sanitize(slate.scene)
            let shot = sanitize(slate.shot)
            if !scene.isEmpty { parts.append("S" + scene) }
            if !shot.isEmpty { parts.append("SH" + shot) }
            parts.append(String(format: "T%02d", slate.take))
        }
        return parts.joined(separator: "_") + ".MOV"
    }

    static func displayName(take: Int) -> String {
        String(format: "Clip %03d", take)
    }

    static func sidecarName(take: Int, kind: String) -> String {
        String(format: "C%03d_%@.JSON", take, kind.uppercased())
    }

    /// Older sidecar names (earlier versions of the app), newest first.
    static func legacySidecarNames(take: Int, kind: String) -> [String] {
        [String(format: "TAKE_%03d_%@.JSON", take, kind.uppercased()),
         String(format: "Take_%03d_%@.json", take, kind.lowercased())]
    }

    /// Reads the current sidecar, falling back to older names.
    static func readSidecar(folder: URL, take: Int, kind: String) -> Data? {
        for name in [sidecarName(take: take, kind: kind)] + legacySidecarNames(take: take, kind: kind) {
            if let data = try? Data(contentsOf: folder.appendingPathComponent(name)) { return data }
        }
        return nil
    }

    /// Removes older sidecars before writing the current one (on a case-insensitive disk some are the same file).
    static func removeLegacySidecars(folder: URL, take: Int, kind: String) {
        for name in legacySidecarNames(take: take, kind: kind) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// Upper case, no diacritics, only A–Z 0–9 and '-' (e.g. "12a" → "12A", "3/b" → "3-B").
    static func sanitize(_ value: String) -> String {
        let folded = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "sk_SK"))
            .uppercased()
        var out = ""
        var lastWasDash = false
        for ch in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(ch) && ch.isASCII {
                out.unicodeScalars.append(ch)
                lastWasDash = false
            } else if !lastWasDash && !out.isEmpty {
                out.append("-")
                lastWasDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    /// Parses a movie name → (clip number, camera). Current names need the camera names to know A from B.
    static func parse(_ fileName: String, names: CameraNames = CameraNames()) -> (take: Int, role: CameraRole)? {
        let range = NSRange(fileName.startIndex..., in: fileName)
        if let m = legacyRegex.firstMatch(in: fileName, range: range),
           let numRange = Range(m.range(at: 1), in: fileName),
           let camRange = Range(m.range(at: 2), in: fileName),
           let number = Int(fileName[numRange]),
           let role = CameraRole(rawValue: fileName[camRange].uppercased()) {
            return (number, role)
        }
        if let m = regex.firstMatch(in: fileName, range: range),
           let prefixRange = Range(m.range(at: 1), in: fileName),
           let numRange = Range(m.range(at: 2), in: fileName),
           let number = Int(fileName[numRange]),
           let role = names.role(forPrefix: String(fileName[prefixRange])) {
            return (number, role)
        }
        return nil
    }

    /// Highest existing clip number + 1 (never reuses a number, even if only one camera's file exists).
    static func nextTakeNumber(in folder: URL, names: CameraNames = CameraNames()) -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let maxTake = files.compactMap { parse($0, names: names)?.take }.max() ?? 0
        return maxTake + 1
    }
}
