//
//  TakeNaming.swift
//  DualCamRecorder
//
//  File names – all upper case:
//      TAKE_007_OBRAZ_12_ZABER_3B_CAMA.MOV
//      TAKE_007_OBRAZ_12_ZABER_3B_CAMB.MOV
//      TAKE_007_MARKS.JSON, TAKE_007_SLATE.JSON   (sidecars keyed by the take number only)
//  OBRAZ / ZABER parts are left out when the slate field is empty.
//  The running TAKE number stays the unique key (auto-numbering, pairing A/B, sidecars).
//  Older names (Take_001_CamA.mov, Take_001_marks.json) are still recognised.
//

import Foundation

enum TakeNaming {
    /// TAKE_<n>[_anything]_CAM<A|B>.MOV – case-insensitive, also matches the old Take_001_CamA.mov.
    private static let regex = try! NSRegularExpression(pattern: "^TAKE_(\\d{3,})(?:_.*)?_CAM([AB])\\.MOV$",
                                                        options: [.caseInsensitive])

    static func fileName(take: Int, role: CameraRole, slate: SlateInfo? = nil) -> String {
        var parts = [String(format: "TAKE_%03d", take)]
        if let slate {
            let scene = sanitize(slate.scene)
            let shot = sanitize(slate.shot)
            if !scene.isEmpty { parts.append("OBRAZ_" + scene) }
            if !shot.isEmpty { parts.append("ZABER_" + shot) }
        }
        parts.append("CAM" + role.rawValue)
        return parts.joined(separator: "_") + ".MOV"
    }

    static func displayName(take: Int) -> String {
        String(format: "TAKE_%03d", take)
    }

    static func sidecarName(take: Int, kind: String) -> String {
        String(format: "TAKE_%03d_%@.JSON", take, kind.uppercased())
    }

    /// Older sidecar name (before upper-case naming).
    static func legacySidecarName(take: Int, kind: String) -> String {
        String(format: "Take_%03d_%@.json", take, kind.lowercased())
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

    /// Parses "TAKE_012_OBRAZ_4_ZABER_2_CAMB.MOV" (or "Take_012_CamB.mov") → (12, .b)
    static func parse(_ fileName: String) -> (take: Int, role: CameraRole)? {
        let range = NSRange(fileName.startIndex..., in: fileName)
        guard let m = regex.firstMatch(in: fileName, range: range),
              let numRange = Range(m.range(at: 1), in: fileName),
              let camRange = Range(m.range(at: 2), in: fileName),
              let number = Int(fileName[numRange]),
              let role = CameraRole(rawValue: fileName[camRange].uppercased())
        else { return nil }
        return (number, role)
    }

    /// Highest existing take number + 1 (never reuses a number, even if only one camera's file exists).
    static func nextTakeNumber(in folder: URL) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let maxTake = names.compactMap { parse($0)?.take }.max() ?? 0
        return maxTake + 1
    }
}
