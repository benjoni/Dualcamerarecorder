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

    /// Where new projects (folders) are created.
    @Published var projectsRootPath: String { didSet { defaults.set(projectsRootPath, forKey: "projectsRootPath") } }
    /// Folder (disk) new takes are written to – the folder of the open project.
    @Published var recordFolderPath: String { didSet { defaults.set(recordFolderPath, forKey: "recordFolderPath") } }
    /// 1 = only camera A is shown and recorded, 2 = cameras A and B.
    @Published var cameraCount: Int { didSet { defaults.set(cameraCount, forKey: "cameraCount") } }
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
    /// Camera names used for earlier recordings of the open project (kept in PROJECT.JSON).
    @Published var earlierCameraNamesA: [String] = []
    @Published var earlierCameraNamesB: [String] = []
    /// Camera list of the open project (Project settings → Camera list), picked on the Record tab.
    @Published var cameras: [ProjectCamera] = []
    /// Backup copy of the project's clips on a second disk (per project).
    @Published var backupEnabled: Bool { didSet { defaults.set(backupEnabled, forKey: "backupEnabled") } }
    @Published var backupRootPath: String { didSet { defaults.set(backupRootPath, forKey: "backupRootPath") } }
    /// Luma waveform over each camera picture (Record and Playback).
    @Published var showWaveform: Bool { didSet { defaults.set(showWaveform, forKey: "showWaveform") } }
    /// Camera setup fields (lens, stop, distance, height, tilt …) under each camera on the Record tab.
    @Published var showCameraSetup: Bool { didSet { defaults.set(showCameraSetup, forKey: "showCameraSetup") } }
    /// Current slate (clapperboard) – used for the next take.
    @Published var slate: SlateInfo {
        didSet { if let data = try? JSONEncoder().encode(slate) { defaults.set(data, forKey: "slate") } }
    }

    init() {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Movies")
        let defaultFolder = movies.appendingPathComponent("DualCamRecorder").path

        recordFolderPath = defaults.string(forKey: "recordFolderPath") ?? defaultFolder
        projectsRootPath = defaults.string(forKey: "projectsRootPath") ?? defaultFolder
        audioChannels = defaults.object(forKey: "audioChannels") as? Int ?? 2
        cameraCount = defaults.object(forKey: "cameraCount") as? Int ?? 2
        forceEightBit = defaults.bool(forKey: "forceEightBit")
        proResFlavor = ProResFlavor(rawValue: defaults.string(forKey: "proResFlavor") ?? "") ?? .proRes422
        deviceA = defaults.string(forKey: "deviceA") ?? ""
        deviceB = defaults.string(forKey: "deviceB") ?? ""
        cameraNameA = defaults.string(forKey: "cameraNameA") ?? "A"
        showWaveform = defaults.bool(forKey: "showWaveform")
        showCameraSetup = defaults.bool(forKey: "showCameraSetup")
        backupEnabled = defaults.bool(forKey: "backupEnabled")
        backupRootPath = defaults.string(forKey: "backupRootPath") ?? ""
        cameraNameB = defaults.string(forKey: "cameraNameB") ?? "B"
        if let data = defaults.data(forKey: "slate"), let saved = try? JSONDecoder().decode(SlateInfo.self, from: data) {
            slate = saved
        } else {
            slate = SlateInfo()
        }
    }

    var twoCameras: Bool { cameraCount >= 2 }

    /// Temporary on/off of each camera in a two-camera project (not saved – both are on when a project opens).
    @Published var cameraAOn = true
    @Published var cameraBOn = true

    /// Camera is shown and recorded.
    func isCameraOn(_ role: CameraRole) -> Bool {
        switch role {
        case .a: return cameraAOn || !twoCameras
        case .b: return twoCameras && cameraBOn
        }
    }

    /// Cameras that will record (in A, B order).
    var activeRoles: [CameraRole] { CameraRole.allCases.filter { isCameraOn($0) } }

    /// The per-project part of the settings.
    var projectSettings: ProjectSettings {
        ProjectSettings(cameraCount: cameraCount, proResFlavor: proResFlavor.rawValue, audioChannels: audioChannels,
                        forceEightBit: forceEightBit, cameraNameA: cameraNameA, cameraNameB: cameraNameB,
                        earlierCameraNamesA: earlierCameraNamesA, earlierCameraNamesB: earlierCameraNamesB,
                        cameras: cameras, deviceA: deviceA, deviceB: deviceB,
                        backupEnabled: backupEnabled, backupRootPath: backupRootPath)
    }

    func apply(_ p: ProjectSettings) {
        cameraCount = p.cameraCount == 1 ? 1 : 2
        proResFlavor = ProResFlavor(rawValue: p.proResFlavor) ?? .proRes422
        audioChannels = p.audioChannels
        forceEightBit = p.forceEightBit
        cameraNameA = p.cameraNameA
        cameraNameB = p.cameraNameB
        earlierCameraNamesA = p.earlierCameraNamesA
        earlierCameraNamesB = p.earlierCameraNamesB
        // Older projects: the list starts with the cameras in use.
        cameras = p.cameras.isEmpty
            ? [ProjectCamera(name: cameraNames.a)] + (cameraCount >= 2 ? [ProjectCamera(name: cameraNames.b)] : [])
            : p.cameras
        deviceA = p.deviceA
        deviceB = p.deviceB
        backupEnabled = p.backupEnabled
        backupRootPath = p.backupRootPath
    }

    /// Sanitized, guaranteed-distinct camera names.
    var cameraNames: CameraNames {
        CameraNames(a: cameraNameA, b: cameraNameB, earlierA: earlierCameraNamesA, earlierB: earlierCameraNamesB)
    }

    /// Cameras to pick from for one input: the list without the camera the other input uses
    /// (+ the camera in use, if it is not in the list).
    func cameraChoices(for role: CameraRole) -> [ProjectCamera] {
        let names = cameraNames
        let mine = names.name(role)
        let other = twoCameras ? names.name(role == .a ? .b : .a) : nil
        var seen = Set<String>()
        var list = cameras.filter { camera in
            let n = TakeNaming.sanitize(camera.name)
            guard !n.isEmpty, n != other, !seen.contains(n) else { return false }
            seen.insert(n)
            return true
        }
        if !seen.contains(mine) { list.insert(ProjectCamera(name: mine), at: 0) }
        return list
    }

    /// Camera of the list an input records with (nil when it is not in the list).
    func camera(_ role: CameraRole) -> ProjectCamera? {
        let name = cameraNames.name(role)
        return cameras.first { TakeNaming.sanitize($0.name) == name }
    }

    /// Remembers the names a recording was made with, so its files are still found after a rename.
    func rememberCameraNames(_ names: CameraNames) {
        if !earlierCameraNamesA.contains(names.a) { earlierCameraNamesA.append(names.a) }
        if !earlierCameraNamesB.contains(names.b) { earlierCameraNamesB.append(names.b) }
    }

    var recordFolderURL: URL { URL(fileURLWithPath: recordFolderPath, isDirectory: true) }

    /// Playback always reads the open project's folder (recording and playback never run at the same time).
    var playbackFolderURL: URL { recordFolderURL }
}
