//
//  AppSettings.swift
//  DualCamRecorder
//

import Foundation
import Combine

/// Persistent user settings (UserDefaults).
final class AppSettings: ObservableObject {
    static let simulatedDeviceID = "simulated"

    private let defaults = UserDefaults.standard

    /// Folder (disk) new takes are written to.
    @Published var recordFolderPath: String { didSet { defaults.set(recordFolderPath, forKey: "recordFolderPath") } }
    /// When true, the Playback tab reads from `playbackFolderPath` (e.g. a different disk) instead of the record folder.
    @Published var separatePlaybackFolder: Bool { didSet { defaults.set(separatePlaybackFolder, forKey: "separatePlaybackFolder") } }
    @Published var playbackFolderPath: String { didSet { defaults.set(playbackFolderPath, forKey: "playbackFolderPath") } }
    /// 0 = no audio, 2 / 8 / 16 embedded SDI channels.
    @Published var audioChannels: Int { didSet { defaults.set(audioChannels, forKey: "audioChannels") } }
    @Published var forceEightBit: Bool { didSet { defaults.set(forceEightBit, forKey: "forceEightBit") } }
    @Published var proResFlavor: ProResFlavor { didSet { defaults.set(proResFlavor.rawValue, forKey: "proResFlavor") } }
    /// Device assignment: DeckLink identifier, `simulatedDeviceID` or "" (none).
    @Published var deviceA: String { didSet { defaults.set(deviceA, forKey: "deviceA") } }
    @Published var deviceB: String { didSet { defaults.set(deviceB, forKey: "deviceB") } }

    init() {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Movies")
        let defaultFolder = movies.appendingPathComponent("DualCamRecorder").path

        recordFolderPath = defaults.string(forKey: "recordFolderPath") ?? defaultFolder
        separatePlaybackFolder = defaults.bool(forKey: "separatePlaybackFolder")
        playbackFolderPath = defaults.string(forKey: "playbackFolderPath") ?? defaultFolder
        audioChannels = defaults.object(forKey: "audioChannels") as? Int ?? 2
        forceEightBit = defaults.bool(forKey: "forceEightBit")
        proResFlavor = ProResFlavor(rawValue: defaults.string(forKey: "proResFlavor") ?? "") ?? .proRes422
        deviceA = defaults.string(forKey: "deviceA") ?? ""
        deviceB = defaults.string(forKey: "deviceB") ?? ""
    }

    var recordFolderURL: URL { URL(fileURLWithPath: recordFolderPath, isDirectory: true) }

    var playbackFolderURL: URL {
        separatePlaybackFolder ? URL(fileURLWithPath: playbackFolderPath, isDirectory: true) : recordFolderURL
    }
}
