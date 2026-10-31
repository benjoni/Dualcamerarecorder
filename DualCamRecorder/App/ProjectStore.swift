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

struct Project: Codable, Equatable {
    var name: String
    var director = ""
    var dop = ""
    var notes = ""
    var createdAt = Date()
    var lastOpenedAt: Date?
    /// Last slate used in this project (shooting day, scene, …) – restored when the project is opened.
    var slate: SlateInfo?
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
        guard var e = current else { return }
        e.project.slate = slate
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
