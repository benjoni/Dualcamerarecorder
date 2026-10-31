//
//  TakeNaming.swift
//  DualCamRecorder
//
//  File names – all upper case, English initials:
//      C007_S12_SH3B_T04_CAMA.MOV     C = clip (running number), S = scene, SH = shot, T = take
//      C007_S12_SH3B_T04_CAMB.MOV
//      C007_MARKS.JSON, C007_SLATE.JSON   (sidecars keyed by the clip number only)
//  S / SH parts are left out when the slate field is empty; T is always present (2 digits).
//  The running clip number is the unique key (auto-numbering, pairing A/B, sidecars).
//  Older names (TAKE_007_…_CAMA.MOV, Take_001_CamA.mov and their sidecars) are still recognised.
//

import Foundation

enum TakeNaming {
    /// C<n>[_anything]_CAM<A|B>.MOV – case-insensitive; also matches TAKE_007_…_CAMA.MOV and Take_001_CamA.mov.
    private static let regex = try! NSRegularExpression(pattern: "^(?:C|TAKE_)(\\d{3,})(?:_.*)?_CAM([AB])\\.MOV$",
                                                        options: [.caseInsensitive])

    static func fileName(take: Int, role: CameraRole, slate: SlateInfo? = nil) -> String {
        var parts = [String(format: "C%03d", take)]
        if let slate {
            let scene = sanitize(slate.scene)
            let shot = sanitize(slate.shot)
            if !scene.isEmpty { parts.append("S" + scene) }
            if !shot.isEmpty { parts.append("SH" + shot) }
            parts.append(String(format: "T%02d", slate.take))
        }
        parts.append("CAM" + role.rawValue)
        return parts.joined(separator: "_") + ".MOV"
    }

    static func displayName(take: Int) -> String {
        String(format: "C%03d", take)
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

    /// Parses "C012_S4_SH2_T03_CAMB.MOV" (or "TAKE_012_…_CAMB.MOV", "Take_012_CamB.mov") → (12, .b)
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
