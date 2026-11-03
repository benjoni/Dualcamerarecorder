//
//  TakeLibrary.swift
//  DualCamRecorder
//
//  Lists Take_###_CamA/B.mov pairs in the playback folder and watches the folder for changes.
//

import Foundation
import Combine

struct Take: Identifiable, Hashable {
    let number: Int
    var camA: URL?
    var camB: URL?
    var modified: Date
    var sizeBytes: Int64
    var marks: TakeMarks?
    var slate: SlateInfo?
    /// Folder the take lives in (marks are saved there).
    var folder: URL? { (camA ?? camB)?.deletingLastPathComponent() }

    var id: Int { number }
    var shootingDay: String { slate?.shootingDay.trimmingCharacters(in: .whitespaces) ?? "" }
    var name: String { TakeNaming.displayName(take: number) }

    /// Camera name the clip was recorded with (from its file name), e.g. "D" after D was renamed back to B.
    func cameraName(_ role: CameraRole, current names: CameraNames) -> String {
        let file = role == .a ? camA : camB
        return file.flatMap { TakeNaming.cameraName(in: $0.lastPathComponent) } ?? names.name(role)
    }
}

struct TakeDayGroup: Identifiable {
    let day: String
    var takes: [Take]
    var id: String { day }
    var title: String { day.isEmpty ? "No shooting day" : "Shooting day \(day)" }
}

extension Take {
    /// Text searched by the clip list search field (lower case, no diacritics).
    var searchText: String {
        var parts = [String(format: "%03d", number), name, camA?.lastPathComponent ?? "", camB?.lastPathComponent ?? ""]
        if let s = slate {
            parts += [s.scene, s.shot, "s\(s.scene)", "sh\(s.shot)", "t\(s.take)", String(format: "t%02d", s.take),
                      "take \(s.take)", "day \(s.shootingDay)", "d\(s.shootingDay)", s.shootingDay,
                      s.cameraClipA, s.cameraClipB, s.note, s.location.rawValue, s.timeOfDay.rawValue,
                      s.setupA.summary, s.setupB.summary]
            if s.good { parts.append("good ★") }
            if s.mos { parts.append("mos") }
        }
        return parts.joined(separator: " ").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Every word of the query must appear somewhere in the clip's text.
    func matches(_ query: String) -> Bool {
        let words = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return true }
        let text = searchText
        return words.allSatisfy { text.contains($0) }
    }
}

final class TakeLibrary: ObservableObject {
    @Published private(set) var takes: [Take] = []
    @Published private(set) var folder: URL?

    /// Take numbers currently being recorded into this folder – hidden until finished.
    var excludedTake: () -> Int? = { nil }
    /// Set when the user switches to the Playback tab: the view then cues the newest clip.
    var cueLatestOnShow = true
    /// Current camera names (needed to tell A from B in file names).
    var cameraNames: () -> CameraNames = { CameraNames() }

    private var watcher: DispatchSourceFileSystemObject?
    private var debounce: DispatchWorkItem?
    private let scanQueue = DispatchQueue(label: "take-library", qos: .utility)

    func setFolder(_ url: URL) {
        if folder?.standardizedFileURL == url.standardizedFileURL { refresh(); return }
        folder = url
        startWatching(url)
        refresh()
    }

    func refresh() {
        guard let folder else { takes = []; return }
        let excluded = excludedTake()
        let names = cameraNames()
        scanQueue.async {
            let found = Self.scan(folder, excluding: excluded, names: names)
            DispatchQueue.main.async {
                if self.folder == folder { self.takes = found }
            }
        }
    }

    private static func scan(_ folder: URL, excluding excluded: Int?, names: CameraNames) -> [Take] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                      options: [.skipsHiddenFiles]) else { return [] }
        var byNumber: [Int: Take] = [:]
        for url in urls {
            guard let parsed = TakeNaming.parse(url.lastPathComponent, names: names), parsed.take != excluded else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let date = values?.contentModificationDate ?? .distantPast
            let size = Int64(values?.fileSize ?? 0)
            var take = byNumber[parsed.take] ?? Take(number: parsed.take, camA: nil, camB: nil, modified: date, sizeBytes: 0)
            if parsed.role == .a { take.camA = url } else { take.camB = url }
            take.modified = max(take.modified, date)
            take.sizeBytes += size
            byNumber[parsed.take] = take
        }
        for (number, take) in byNumber {
            byNumber[number]?.marks = TakeMarksStore.load(folder: folder, take: take.number)
            byNumber[number]?.slate = TakeSlateStore.load(folder: folder, take: take.number)
        }
        return sortedByShootingDay(Array(byNumber.values))
    }

    /// Newest shooting day first (natural order: "10" after "9", "D03" after "D02"),
    /// clips without a shooting day last; inside a day newest clip first.
    static func sortedByShootingDay(_ takes: [Take]) -> [Take] {
        takes.sorted { a, b in
            let da = a.shootingDay, db = b.shootingDay
            if da != db {
                if da.isEmpty { return false }
                if db.isEmpty { return true }
                return da.localizedStandardCompare(db) == .orderedDescending
            }
            return a.number > b.number
        }
    }

    /// Clips grouped by shooting day, in list order.
    var groupedByShootingDay: [TakeDayGroup] { Self.group(takes) }

    /// Groups already sorted clips by shooting day.
    static func group(_ takes: [Take]) -> [TakeDayGroup] {
        var groups: [TakeDayGroup] = []
        for take in takes {
            if let last = groups.last, last.day == take.shootingDay {
                groups[groups.count - 1].takes.append(take)
            } else {
                groups.append(TakeDayGroup(day: take.shootingDay, takes: [take]))
            }
        }
        return groups
    }

    /// Files of a clip: both camera movies, its slate and its IN / OUT marks (those that exist).
    static func files(of take: Take) -> [URL] {
        var urls = [take.camA, take.camB].compactMap { $0 }
        if let folder = take.folder {
            urls += [TakeSlateStore.url(folder: folder, take: take.number), TakeMarksStore.url(folder: folder, take: take.number)]
        }
        return urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Moves all files of the clip to the Trash (they can be put back from there) and re-scans the folder.
    func moveToTrash(_ take: Take) throws {
        for url in Self.files(of: take) {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        takes.removeAll { $0.id == take.id }
        refresh()
    }

    /// Most recently recorded clip (highest clip number), regardless of the sort order.
    var latestTake: Take? { takes.max { $0.number < $1.number } }

    private func startWatching(_ url: URL) {
        watcher?.cancel()
        watcher = nil
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete],
                                                               queue: .main)
        source.setEventHandler { [weak self] in self?.scheduleRefresh() }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    private func scheduleRefresh() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}
