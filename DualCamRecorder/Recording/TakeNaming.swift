//
//  TakeNaming.swift
//  DualCamRecorder
//

import Foundation

/// Take_001_CamA.mov / Take_001_CamB.mov
enum TakeNaming {
    private static let regex = try! NSRegularExpression(pattern: "^Take_(\\d{3,})_Cam([AB])\\.mov$", options: [.caseInsensitive])

    static func fileName(take: Int, role: CameraRole) -> String {
        String(format: "Take_%03d_%@.mov", take, role.fileSuffix)
    }

    static func displayName(take: Int) -> String {
        String(format: "Take_%03d", take)
    }

    /// Parses "Take_012_CamB.mov" → (12, .b)
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
