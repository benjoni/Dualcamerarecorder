//
//  ProjectStore.swift
//  DualCamRecorder
//
//  Projects: every project is a folder (named like the project) that holds the recordings and a
//  PROJECT.JSON with the project details and the project's last slate.
//  Known projects = sub-folders of the projects location that contain PROJECT.JSON
//  + folders the user opened elsewhere (remembered in UserDefaults).
//

import Foundation
import Combine
import AppKit

/// A camera of the project's list: "C" + "Ronin 4D". The name goes into the file names (C007_…).
struct ProjectCamera: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var model = ""

    /// "C · Ronin 4D" (or just "C").
    var title: String {
        let m = model.trimmingCharacters(in: .whitespaces)
        return m.isEmpty ? TakeNaming.sanitize(name) : "\(TakeNaming.sanitize(name)) · \(m)"
    }
}

/// Settings stored per project (applied when the project is opened).
struct ProjectSettings: Codable, Equatable {
    var cameraCount = 2
    var proResFlavor = ProResFlavor.proRes422.rawValue
    var audioChannels = 2
    var forceEightBit = false
    var cameraNameA = "A"
    var cameraNameB = "B"
    /// Names the cameras had before (files recorded with them are still recognised).
    var earlierCameraNamesA: [String] = []
    var earlierCameraNamesB: [String] = []
    /// Cameras of the production (Camera A Venice, Camera C Ronin 4D …) – picked on the Record tab.
    var cameras: [ProjectCamera] = []
    var deviceA = ""
    var deviceB = ""
    /// Monitor on a DeckLink output (the first device with an output, e.g. UltraStudio Monitor 3G)
    /// and what it shows (MonitorSource: a / b / both).
    var monitorEnabled = false
    var monitorSource = MonitorSource.a.rawValue
    /// Flip / flop of each input's picture (also in the recorded files).
    var orientationA = PictureOrientation()
    var orientationB = PictureOrientation()
    /// Aspect ratio mask over each camera's picture on the screen (Record and Playback; not in the file).
    var maskA = FrameMask()
    var maskB = FrameMask()
    /// How each camera's own REC is read from its SDI signal, and whether the app records together with it.
    var recDetectionA = CameraRecDetection.flag
    var recDetectionB = CameraRecDetection.flag
    var cameraTrigger = CameraTrigger.off
    /// Second copy of all clips on another disk: <backupRootPath>/<project folder name>.
    var backupEnabled = false
    var backupRootPath = ""
    /// H.265 data rate (Mbit/s for 1080p).
    var hevcMbps = ProResFlavor.defaultHEVCRate
    /// Audio interface (Focusrite …): how it is used and which device.
    var audioInterfaceMode = AudioInterfaceMode.off
    var audioInterfaceID = ""
    /// Sound against picture (ms): + delays the sound, − moves it earlier.
    var audioInterfaceDelayMs = 0
}

extension ProjectSettings {
    /// Tolerant decoding (missing keys keep their defaults).
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cameraCount = try c.decodeIfPresent(Int.self, forKey: .cameraCount) ?? cameraCount
        proResFlavor = try c.decodeIfPresent(String.self, forKey: .proResFlavor) ?? proResFlavor
        audioChannels = try c.decodeIfPresent(Int.self, forKey: .audioChannels) ?? audioChannels
        forceEightBit = try c.decodeIfPresent(Bool.self, forKey: .forceEightBit) ?? forceEightBit
        cameraNameA = try c.decodeIfPresent(String.self, forKey: .cameraNameA) ?? cameraNameA
        cameraNameB = try c.decodeIfPresent(String.self, forKey: .cameraNameB) ?? cameraNameB
        earlierCameraNamesA = try c.decodeIfPresent([String].self, forKey: .earlierCameraNamesA) ?? earlierCameraNamesA
        earlierCameraNamesB = try c.decodeIfPresent([String].self, forKey: .earlierCameraNamesB) ?? earlierCameraNamesB
        cameras = try c.decodeIfPresent([ProjectCamera].self, forKey: .cameras) ?? cameras
        deviceA = try c.decodeIfPresent(String.self, forKey: .deviceA) ?? deviceA
        deviceB = try c.decodeIfPresent(String.self, forKey: .deviceB) ?? deviceB
        monitorEnabled = try c.decodeIfPresent(Bool.self, forKey: .monitorEnabled) ?? monitorEnabled
        monitorSource = try c.decodeIfPresent(String.self, forKey: .monitorSource) ?? monitorSource
        orientationA = try c.decodeIfPresent(PictureOrientation.self, forKey: .orientationA) ?? orientationA
        orientationB = try c.decodeIfPresent(PictureOrientation.self, forKey: .orientationB) ?? orientationB
        maskA = try c.decodeIfPresent(FrameMask.self, forKey: .maskA) ?? maskA
        maskB = try c.decodeIfPresent(FrameMask.self, forKey: .maskB) ?? maskB
        recDetectionA = (try? c.decodeIfPresent(CameraRecDetection.self, forKey: .recDetectionA)) ?? recDetectionA
        recDetectionB = (try? c.decodeIfPresent(CameraRecDetection.self, forKey: .recDetectionB)) ?? recDetectionB
        cameraTrigger = (try? c.decodeIfPresent(CameraTrigger.self, forKey: .cameraTrigger)) ?? cameraTrigger
        backupEnabled = try c.decodeIfPresent(Bool.self, forKey: .backupEnabled) ?? backupEnabled
        backupRootPath = try c.decodeIfPresent(String.self, forKey: .backupRootPath) ?? backupRootPath
        hevcMbps = (try? c.decodeIfPresent(Int.self, forKey: .hevcMbps)) ?? hevcMbps
        audioInterfaceMode = (try? c.decodeIfPresent(AudioInterfaceMode.self, forKey: .audioInterfaceMode)) ?? audioInterfaceMode
        audioInterfaceID = (try? c.decodeIfPresent(String.self, forKey: .audioInterfaceID)) ?? audioInterfaceID
        audioInterfaceDelayMs = (try? c.decodeIfPresent(Int.self, forKey: .audioInterfaceDelayMs)) ?? audioInterfaceDelayMs
    }
}

/// Camera mounted upside down / shooting through a mirror: flip = upside down, flop = mirrored left–right
/// (both = turned by 180°).
struct PictureOrientation: Codable, Equatable {
    var flip = false
    var flop = false
    var isTurned: Bool { flip || flop }
    /// "FLIP", "FLOP", "FLIP + FLOP" or "".
    var label: String { [flip ? "FLIP" : nil, flop ? "FLOP" : nil].compactMap { $0 }.joined(separator: " + ") }
}

/// Black bars over a 16:9 picture showing the frame of a wider (or narrower) format – a framing guide only.
struct FrameMask: Codable, Equatable {
    enum Ratio: String, Codable, CaseIterable {
        case off, r185, r200, r235, custom
        var title: String {
            switch self {
            case .off: return "Off"
            case .r185: return "1.85"
            case .r200: return "2:1"
            case .r235: return "2.35"
            case .custom: return "Custom"
            }
        }
    }
    var ratio = Ratio.off
    /// Width ÷ height used by `custom` (e.g. 2.39, 1.33).
    var customRatio = 2.39
    /// Darkness of the bars, 0 … 1.
    var opacity = 1.0

    static let customRange = 1.0...3.0

    /// Width ÷ height of the masked frame (nil = off).
    var aspect: Double? {
        switch ratio {
        case .off: return nil
        case .r185: return 1.85
        case .r200: return 2.0
        case .r235: return 2.35
        case .custom: return min(max(customRatio, Self.customRange.lowerBound), Self.customRange.upperBound)
        }
    }

    var isOn: Bool { aspect != nil }
    /// "2.35", "2:1", "2.39" …
    var label: String {
        guard let aspect else { return "Mask" }
        if ratio == .custom { return String(format: "%.2f", aspect) }
        return ratio.title
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ratio = (try? c.decodeIfPresent(Ratio.self, forKey: .ratio)) ?? .off
        customRatio = try c.decodeIfPresent(Double.self, forKey: .customRatio) ?? customRatio
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? opacity
    }
}

struct Project: Codable, Equatable {
    var name: String
    var director = ""
    var dop = ""
    var notes = ""
    var createdAt = Date()
    var lastOpenedAt: Date?
    /// Last slate used in this project (shooting day, scene, …) – restored when the project is opened.
    var slate: SlateInfo?
    /// Cameras, codec, audio … of this project (nil for projects from older versions).
    var settings: ProjectSettings?
}

struct ProjectEntry: Identifiable, Equatable {
    var folder: URL
    var project: Project
    var id: String { folder.standardizedFileURL.path }

    /// Number of recorded clips (A/B pairs count once).
    func clipCount(names: CameraNames) -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return Set(files.compactMap { TakeNaming.parse($0, names: names)?.take }).count
    }
}

enum ProjectError: LocalizedError {
    case emptyName
    case folderExists(String)
    case cannotCreate(String)

    var errorDescription: String? {
        switch self {
        case .emptyName: return "Enter a project name."
        case .folderExists(let p): return "A folder with this name already exists: \(p)"
        case .cannotCreate(let s): return "Could not create the project: \(s)"
        }
    }
}

final class ProjectStore: ObservableObject {
    static let fileName = "PROJECT.JSON"

    @Published private(set) var projects: [ProjectEntry] = []
    @Published private(set) var current: ProjectEntry?

    private let settings: AppSettings
    private let defaults = UserDefaults.standard
    private let knownKey = "knownProjectFolders"

    init(settings: AppSettings) {
        self.settings = settings
        reload()
    }

    var rootURL: URL { URL(fileURLWithPath: settings.projectsRootPath, isDirectory: true) }

    // MARK: - Listing

    func reload() {
        var folders = Set<String>()
        let fm = FileManager.default
        if let subs = try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey],
                                                 options: [.skipsHiddenFiles]) {
            for url in subs where fm.fileExists(atPath: url.appendingPathComponent(Self.fileName).path) {
                folders.insert(url.standardizedFileURL.path)
            }
        }
        for path in defaults.stringArray(forKey: knownKey) ?? [] where
            fm.fileExists(atPath: URL(fileURLWithPath: path).appendingPathComponent(Self.fileName).path) {
            folders.insert(path)
        }
        projects = folders.compactMap { path in
            let url = URL(fileURLWithPath: path, isDirectory: true)
            return Self.load(folder: url).map { ProjectEntry(folder: url, project: $0) }
        }
        .sorted { ($0.project.lastOpenedAt ?? $0.project.createdAt) > ($1.project.lastOpenedAt ?? $1.project.createdAt) }
    }

    // MARK: - Create / edit

    /// Creates `<location>/<name>` and PROJECT.JSON inside it.
    @discardableResult
    func create(name rawName: String, director: String, dop: String, notes: String, location: URL) throws -> ProjectEntry {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ProjectError.emptyName }
        let folder = location.appendingPathComponent(Self.folderName(for: name), isDirectory: true)
        if FileManager.default.fileExists(atPath: folder.path) { throw ProjectError.folderExists(folder.path) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw ProjectError.cannotCreate(error.localizedDescription)
        }
        let project = Project(name: name, director: director, dop: dop, notes: notes)
        try Self.save(project, folder: folder)
        remember(folder)
        reload()
        return ProjectEntry(folder: folder, project: project)
    }

    /// Saves edited details; a new name also renames the folder.
    @discardableResult
    func update(_ entry: ProjectEntry, name rawName: String, director: String, dop: String, notes: String) throws -> ProjectEntry {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ProjectError.emptyName }
        var folder = entry.folder
        if name != entry.project.name {
            let target = folder.deletingLastPathComponent().appendingPathComponent(Self.folderName(for: name), isDirectory: true)
            if target.standardizedFileURL.path.lowercased() != folder.standardizedFileURL.path.lowercased(),
               FileManager.default.fileExists(atPath: target.path) {
                throw ProjectError.folderExists(target.path)
            }
            try FileManager.default.moveItem(at: folder, to: target)
            forget(folder)
            folder = target
            remember(folder)
        }
        var project = entry.project
        project.name = name
        project.director = director
        project.dop = dop
        project.notes = notes
        try Self.save(project, folder: folder)
        let updated = ProjectEntry(folder: folder, project: project)
        if current?.id == entry.id { current = updated }
        reload()
        return updated
    }

    /// Adds an existing folder as a project (creates PROJECT.JSON named after the folder if missing).
    @discardableResult
    func addExisting(folder: URL) throws -> ProjectEntry {
        let project = Self.load(folder: folder) ?? Project(name: folder.lastPathComponent)
        try Self.save(project, folder: folder)
        remember(folder)
        reload()
        return ProjectEntry(folder: folder, project: project)
    }

    /// Removes the project from the list only – files stay on disk.
    func removeFromList(_ entry: ProjectEntry) {
        forget(entry.folder)
        // Projects inside the projects location are found by scanning; hide them by renaming the marker.
        if entry.folder.deletingLastPathComponent().standardizedFileURL == rootURL.standardizedFileURL {
            let marker = entry.folder.appendingPathComponent(Self.fileName)
            try? FileManager.default.moveItem(at: marker, to: entry.folder.appendingPathComponent("PROJECT_REMOVED.JSON"))
        }
        reload()
    }

    func showInFinder(_ entry: ProjectEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([entry.folder])
    }

    // MARK: - Open / close

    func markOpened(_ entry: ProjectEntry) -> ProjectEntry {
        var e = entry
        e.project.lastOpenedAt = Date()
        try? Self.save(e.project, folder: e.folder)
        remember(e.folder)
        current = e
        reload()
        return e
    }

    /// Stores the slate in the current project and leaves it.
    func closeCurrent(saving slate: SlateInfo) {
        guard var e = current else { return }
        e.project.slate = slate
        try? Self.save(e.project, folder: e.folder)
        current = nil
        reload()
    }

    func saveSlate(_ slate: SlateInfo) {
        guard var e = current, e.project.slate != slate else { return }
        e.project.slate = slate
        try? Self.save(e.project, folder: e.folder)
        current = e
    }

    func saveSettings(_ settings: ProjectSettings) {
        guard var e = current, e.project.settings != settings else { return }
        e.project.settings = settings
        try? Self.save(e.project, folder: e.folder)
        current = e
    }

    // MARK: - Files

    /// Folder name = project name; only characters macOS cannot use in a name are replaced.
    static func folderName(for name: String) -> String {
        var s = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        while s.hasPrefix(".") { s.removeFirst() }
        return s.isEmpty ? "Project" : s
    }

    static func load(folder: URL) -> Project? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Project.self, from: data)
    }

    static func save(_ project: Project, folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(project).write(to: folder.appendingPathComponent(fileName), options: .atomic)
    }

    private func remember(_ folder: URL) {
        var list = defaults.stringArray(forKey: knownKey) ?? []
        let path = folder.standardizedFileURL.path
        if !list.contains(path) { list.append(path) }
        defaults.set(list, forKey: knownKey)
    }

    private func forget(_ folder: URL) {
        let path = folder.standardizedFileURL.path
        defaults.set((defaults.stringArray(forKey: knownKey) ?? []).filter { $0 != path }, forKey: knownKey)
    }
}
