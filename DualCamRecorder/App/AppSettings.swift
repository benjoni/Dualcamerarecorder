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
    /// Camera names at the start of the file names (A007_… / B007_…).
    @Published var cameraNameA: String { didSet { defaults.set(cameraNameA, forKey: "cameraNameA") } }
    @Published var cameraNameB: String { didSet { defaults.set(cameraNameB, forKey: "cameraNameB") } }
    /// Luma waveform over each camera picture (Record and Playback).
    @Published var showWaveform: Bool { didSet { defaults.set(showWaveform, forKey: "showWaveform") } }
    /// Current slate (clapperboard) – used for the next take.
    @Published var slate: SlateInfo {
        didSet { if let data = try? JSONEncoder().encode(slate) { defaults.set(data, forKey: "slate") } }
    }

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
        cameraNameA = defaults.string(forKey: "cameraNameA") ?? "A"
        showWaveform = defaults.bool(forKey: "showWaveform")
        cameraNameB = defaults.string(forKey: "cameraNameB") ?? "B"
        if let data = defaults.data(forKey: "slate"), let saved = try? JSONDecoder().decode(SlateInfo.self, from: data) {
            slate = saved
        } else {
            slate = SlateInfo()
        }
    }

    /// Sanitized, guaranteed-distinct camera names.
    var cameraNames: CameraNames { CameraNames(a: cameraNameA, b: cameraNameB) }

    var recordFolderURL: URL { URL(fileURLWithPath: recordFolderPath, isDirectory: true) }

    var playbackFolderURL: URL {
        separatePlaybackFolder ? URL(fileURLWithPath: playbackFolderPath, isDirectory: true) : recordFolderURL
    }
}
