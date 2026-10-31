//
//  BackupManager.swift
//  DualCamRecorder
//
//  Second copy of the project on another disk: <backup root>/<project folder name>/.
//  After every take (and on demand) all files that are missing or different in the backup are copied:
//  movies, slate / marks JSON, CLIPLOG.CSV, PROJECT.JSON. Each file is copied to a temporary name,
//  checked by size and then renamed, so the backup never contains a half-written file under its real name.
//

import Foundation
import Combine

final class BackupManager: ObservableObject {
    enum State: Equatable {
        case off
        case idle                 // up to date
        case copying(remaining: Int, current: String)
        case diskMissing(String)
        case failed(String)
    }

    @Published private(set) var state: State = .off
    @Published private(set) var lastBackup: Date?
    @Published private(set) var copiedClipFiles = 0

    private let queue = DispatchQueue(label: "backup", qos: .utility)
    private var running = false
    private var again = false
    private var source: URL?
    private var destination: URL?
    /// File names that must not be copied now (the take that is being recorded).
    var isExcluded: (String) -> Bool = { _ in false }

    /// Short status for the Record screen.
    var shortStatus: String? {
        switch state {
        case .off: return nil
        case .idle: return "Backup ✓ up to date"
        case .copying(let n, _): return "Backup: copying \(n) file\(n == 1 ? "" : "s")…"
        case .diskMissing: return "Backup disk not connected"
        case .failed: return "Backup failed"
        }
    }

    var isProblem: Bool {
        switch state {
        case .diskMissing, .failed: return true
        default: return false
        }
    }

    /// Backup folder for a project: <root>/<project folder name>.
    static func destination(root: String, projectFolder: URL) -> URL? {
        guard !root.isEmpty else { return nil }
        return URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent(projectFolder.lastPathComponent, isDirectory: true)
    }

    /// Sets what to back up (nil destination = backup off) and starts a sync.
    func configure(source: URL?, destination: URL?) {
        self.source = source
        self.destination = destination
        if source == nil || destination == nil {
            state = .off
            return
        }
        sync()
    }

    /// Copies everything that is missing or different. Calls are coalesced while a sync is running.
    func sync() {
        guard let source, let destination else { state = .off; return }
        if running { again = true; return }
        running = true
        queue.async { [weak self] in
            self?.runSync(source: source, destination: destination)
        }
    }

    private func runSync(source: URL, destination: URL) {
        let fm = FileManager.default
        func publish(_ s: State) { DispatchQueue.main.async { self.state = s } }

        // The backup disk must be mounted (the root folder's volume has to exist).
        let root = destination.deletingLastPathComponent()
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            publish(.diskMissing(root.path))
            finish()
            return
        }
        do {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            publish(.failed("Cannot create \(destination.path): \(error.localizedDescription)"))
            finish()
            return
        }

        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let files = (try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: keys,
                                                 options: [.skipsHiddenFiles])) ?? []
        var todo: [(URL, Int64, Date)] = []
        let excluded = DispatchQueue.main.sync { files.map(\.lastPathComponent).filter(self.isExcluded) }
        for file in files where !excluded.contains(file.lastPathComponent) {
            guard let v = try? file.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            let size = Int64(v.fileSize ?? 0)
            let date = v.contentModificationDate ?? .distantPast
            let target = destination.appendingPathComponent(file.lastPathComponent)
            if let t = try? target.resourceValues(forKeys: Set(keys)),
               Int64(t.fileSize ?? -1) == size,
               (t.contentModificationDate ?? .distantPast) >= date {
                continue   // already backed up
            }
            todo.append((file, size, date))
        }
        // Small files (JSON / CSV) first, then movies.
        todo.sort { $0.1 < $1.1 }

        var copiedMovies = 0
        for (index, item) in todo.enumerated() {
            let (file, size, date) = item
            publish(.copying(remaining: todo.count - index, current: file.lastPathComponent))
            let target = destination.appendingPathComponent(file.lastPathComponent)
            let temp = destination.appendingPathComponent("." + file.lastPathComponent + ".copying")
            do {
                try? fm.removeItem(at: temp)
                try fm.copyItem(at: file, to: temp)
                let copiedSize = Int64((try? temp.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1)
                guard copiedSize == size else {
                    try? fm.removeItem(at: temp)
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey:
                        "Size check failed for \(file.lastPathComponent)"])
                }
                try? fm.setAttributes([.modificationDate: date], ofItemAtPath: temp.path)
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.moveItem(at: temp, to: target)
                if file.pathExtension.uppercased() == "MOV" { copiedMovies += 1 }
            } catch {
                try? fm.removeItem(at: temp)
                // Disk unplugged in the middle?
                if !fm.fileExists(atPath: root.path) {
                    publish(.diskMissing(root.path))
                } else {
                    publish(.failed(error.localizedDescription))
                }
                finish()
                return
            }
        }
        DispatchQueue.main.async {
            self.state = .idle
            self.lastBackup = Date()
            self.copiedClipFiles += copiedMovies
        }
        finish()
    }

    private func finish() {
        DispatchQueue.main.async {
            self.running = false
            if self.again {
                self.again = false
                self.sync()
            }
        }
    }
}
