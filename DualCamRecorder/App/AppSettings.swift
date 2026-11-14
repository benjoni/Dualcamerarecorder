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
    /// Audio interface (Focusrite …) per project: how it is used and which device (AVCaptureDevice.uniqueID).
    @Published var audioInterfaceMode = AudioInterfaceMode.off
    @Published var audioInterfaceID = ""
    /// Sound against picture (ms): + delays the sound, − moves it earlier.
    @Published var audioInterfaceDelayMs = 0
    @Published var forceEightBit: Bool { didSet { defaults.set(forceEightBit, forKey: "forceEightBit") } }
    @Published var proResFlavor: ProResFlavor { didSet { defaults.set(proResFlavor.rawValue, forKey: "proResFlavor") } }
    /// H.265 data rate (Mbit/s for 1080p).
    @Published var hevcMbps: Int { didSet { defaults.set(hevcMbps, forKey: "hevcMbps") } }
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
    /// Blackmagic monitor on a DeckLink output (per project): on / off and what it shows (toolbar).
    @Published var monitorEnabled = false
    @Published var monitorSource = MonitorSource.a
    /// Picture of each input turned round (per project): flip = upside down, flop = mirrored left–right.
    /// Applied before the screen, monitor, phones and the recorded file.
    @Published var orientationA = PictureOrientation()
    @Published var orientationB = PictureOrientation()
    /// Aspect ratio mask over each camera's picture (per project) – Record and Playback screens only.
    @Published var maskA = FrameMask()
    @Published var maskB = FrameMask()
    /// LUT of each camera (per project), burned into the pictures and the file: file name in the LUT library, "" = none.
    /// Screen, monitor and phones only – the recorded file stays as the camera sends it.
    @Published var lutA = ""
    @Published var lutB = ""
    /// Info bar of each input (per project): who is on the camera – operator, focus puller …
    /// Under the picture on Record and on the Blackmagic monitor; not in the recorded file.
    @Published var infoA = ""
    @Published var infoB = ""
    /// Camera's own REC read from the SDI signal (per input) and recording together with the camera (per project).
    @Published var recDetectionA = CameraRecDetection.flag
    @Published var recDetectionB = CameraRecDetection.flag
    @Published var cameraTrigger = CameraTrigger.off
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
        hevcMbps = defaults.object(forKey: "hevcMbps") as? Int ?? ProResFlavor.defaultHEVCRate
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

    func orientation(_ role: CameraRole) -> PictureOrientation {
        role == .a ? orientationA : orientationB
    }

    func setOrientation(_ o: PictureOrientation, for role: CameraRole) {
        if role == .a { orientationA = o } else { orientationB = o }
    }

    func mask(_ role: CameraRole) -> FrameMask {
        role == .a ? maskA : maskB
    }

    func setMask(_ m: FrameMask, for role: CameraRole) {
        if role == .a { maskA = m } else { maskB = m }
    }

    func lut(_ role: CameraRole) -> String {
        role == .a ? lutA : lutB
    }

    func setLUT(_ name: String, for role: CameraRole) {
        if role == .a { lutA = name } else { lutB = name }
    }

    func info(_ role: CameraRole) -> String {
        role == .a ? infoA : infoB
    }

    func setInfo(_ text: String, for role: CameraRole) {
        if role == .a { infoA = text } else { infoB = text }
    }

    func recDetection(_ role: CameraRole) -> CameraRecDetection {
        role == .a ? recDetectionA : recDetectionB
    }

    func setRecDetection(_ d: CameraRecDetection, for role: CameraRole) {
        if role == .a { recDetectionA = d } else { recDetectionB = d }
    }

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
                        monitorEnabled: monitorEnabled, monitorSource: monitorSource.rawValue,
                        orientationA: orientationA, orientationB: orientationB,
                        maskA: maskA, maskB: maskB, lutA: lutA, lutB: lutB,
                        recDetectionA: recDetectionA, recDetectionB: recDetectionB, cameraTrigger: cameraTrigger,
                        backupEnabled: backupEnabled, backupRootPath: backupRootPath, hevcMbps: hevcMbps,
                        audioInterfaceMode: audioInterfaceMode, audioInterfaceID: audioInterfaceID,
                        audioInterfaceDelayMs: audioInterfaceDelayMs, infoA: infoA, infoB: infoB)
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
        monitorEnabled = p.monitorEnabled
        monitorSource = MonitorSource(rawValue: p.monitorSource) ?? .a
        orientationA = p.orientationA
        orientationB = p.orientationB
        maskA = p.maskA
        maskB = p.maskB
        lutA = p.lutA
        lutB = p.lutB
        recDetectionA = p.recDetectionA
        recDetectionB = p.recDetectionB
        cameraTrigger = p.cameraTrigger
        backupEnabled = p.backupEnabled
        backupRootPath = p.backupRootPath
        hevcMbps = p.hevcMbps
        audioInterfaceMode = p.audioInterfaceMode
        audioInterfaceID = p.audioInterfaceID
        audioInterfaceDelayMs = p.audioInterfaceDelayMs
        infoA = p.infoA
        infoB = p.infoB
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
