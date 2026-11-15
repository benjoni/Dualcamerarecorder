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
            if !s.episode.isEmpty { parts += [s.episode, "e\(s.episode)", "ep \(s.episode)"] }
            parts += [s.scene, s.shot, "s\(s.scene)", "sh\(s.shot)", "t\(s.take)", String(format: "t%02d", s.take),
                      "take \(s.take)", "day \(s.shootingDay)", "d\(s.shootingDay)", s.shootingDay,
                      s.cameraClipA, s.cameraClipB, s.note, s.location.rawValue, s.timeOfDay.rawValue,
                      s.setupA.summary, s.setupB.summary]
            if s.good { parts.append("good ★") }
            if s.mos { parts.append("mos") }
        }
        return parts.joined(separator: " ").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Every word of the query must match. Slate numbers match exactly: "E3 S22 SH5 T4" (also "ep 3", "scene 22",
    /// "shot 5", "take 4", Slovak "epizoda / obraz / zaber / pokus 4", or "3/22/5/4" = episode/scene/shot/take,
    /// "22/5/4" = scene/shot/take) – S2 does not find scene 22. Any other word may appear anywhere in the clip's text.
    func matches(_ query: String) -> Bool {
        let parsed = SlateQuery(query)
        guard !parsed.isEmpty else { return true }
        if !parsed.fields.isEmpty {
            guard let s = slate else { return false }
            for (field, value) in parsed.fields {
                switch field {
                case .episode: if TakeNaming.sanitize(s.episode) != value { return false }
                case .scene: if TakeNaming.sanitize(s.scene) != value { return false }
                case .shot: if TakeNaming.sanitize(s.shot) != value { return false }
                case .take: if Int(value) != s.take { return false }
                }
            }
        }
        guard !parsed.words.isEmpty else { return true }
        let text = searchText
        return parsed.words.allSatisfy { text.contains($0) }
    }
}

/// Clip list filter by slate numbers (Playback: Episode / Scene / Shot / Take menus). Nil = any.
/// Each menu offers only the values of recorded clips that match the menus before it
/// (scenes of the chosen episode, shots of the chosen scene …).
struct SlateFilter: Equatable {
    var episode: String?
    var scene: String?
    var shot: String?
    var take: Int?

    var isActive: Bool { episode != nil || scene != nil || shot != nil || take != nil }

    func matches(_ take: Take) -> Bool { matches(take, upTo: 4) }

    /// Only the first `depth` fields (0 = none, 1 = episode, 2 = + scene, 3 = + shot, 4 = all).
    private func matches(_ t: Take, upTo depth: Int) -> Bool {
        guard isActive else { return true }
        guard let s = t.slate else { return false }
        if depth >= 1, let episode, TakeNaming.sanitize(s.episode) != episode { return false }
        if depth >= 2, let scene, TakeNaming.sanitize(s.scene) != scene { return false }
        if depth >= 3, let shot, TakeNaming.sanitize(s.shot) != shot { return false }
        if depth >= 4, let take, s.take != take { return false }
        return true
    }

    /// Values for one menu: (key compared, title shown), in natural order (2 < 10, 12A < 12B).
    struct Option: Hashable { let key: String; let title: String }

    func episodes(in takes: [Take]) -> [Option] { options(takes, depth: 0) { $0.episode } }
    func scenes(in takes: [Take]) -> [Option] { options(takes, depth: 1) { $0.scene } }
    func shots(in takes: [Take]) -> [Option] { options(takes, depth: 2) { $0.shot } }
    func takes(in takes: [Take]) -> [Int] {
        Array(Set(takes.filter { matches($0, upTo: 3) }.compactMap { $0.slate?.take })).sorted()
    }

    private func options(_ takes: [Take], depth: Int, _ value: (SlateInfo) -> String) -> [Option] {
        var seen: [String: String] = [:]
        for t in takes where matches(t, upTo: depth) {
            guard let s = t.slate else { continue }
            let raw = value(s).trimmingCharacters(in: .whitespaces)
            let key = TakeNaming.sanitize(raw)
            if !key.isEmpty, seen[key] == nil { seen[key] = raw }
        }
        return seen.map { Option(key: $0.key, title: $0.value) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// After a menu changed: clears the menus after it whose value no longer exists among the clips.
    mutating func dropMissing(in takes: [Take]) {
        if let scene, !scenes(in: takes).contains(where: { $0.key == scene }) { self.scene = nil }
        if let shot, !shots(in: takes).contains(where: { $0.key == shot }) { self.shot = nil }
        if let take, !self.takes(in: takes).contains(take) { self.take = nil }
    }
}

/// Clip search split into exact slate numbers and free words.
struct SlateQuery {
    enum Field { case episode, scene, shot, take }
    /// Wanted values, compared in TakeNaming.sanitize form (upper case; the take as a number).
    private(set) var fields: [(Field, String)] = []
    /// Lower case, without diacritics – searched anywhere in Take.searchText.
    private(set) var words: [String] = []
    var isEmpty: Bool { fields.isEmpty && words.isEmpty }

    /// Words naming a field when the number follows as the next word ("scene 22").
    private static let keywords: [String: Field] = [
        "e": .episode, "ep": .episode, "episode": .episode, "epizoda": .episode,
        "s": .scene, "sc": .scene, "scene": .scene, "obraz": .scene,
        "sh": .shot, "shot": .shot, "zaber": .shot,
        "t": .take, "take": .take, "pokus": .take,
    ]
    /// Prefixes glued to the number ("E3", "SH5", "T04") – longest first, so SH5 is a shot, not scene "H5".
    private static let prefixes: [(String, Field)] = [
        ("episode", .episode), ("epizoda", .episode), ("scene", .scene), ("obraz", .scene), ("shot", .shot),
        ("zaber", .shot), ("take", .take), ("pokus", .take), ("ep", .episode), ("sc", .scene), ("sh", .shot),
        ("e", .episode), ("s", .scene), ("t", .take),
    ]

    init(_ query: String) {
        let tokens = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            // "scene 22" – a field word and a number (or 12B …) after it.
            if let field = Self.keywords[token], i + 1 < tokens.count, Self.isValue(tokens[i + 1]) {
                add(field, tokens[i + 1])
                i += 2
                continue
            }
            // "3/22/5/4" or "22/5/4".
            let slashParts = token.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            if slashParts.count == 3 || slashParts.count == 4, slashParts.allSatisfy({ !$0.isEmpty }),
               Self.isValue(slashParts.last!) {
                let order: [Field] = slashParts.count == 4 ? [.episode, .scene, .shot, .take] : [.scene, .shot, .take]
                for (field, value) in zip(order, slashParts) { add(field, value) }
                i += 1
                continue
            }
            // "E3", "SH5", "T04".
            if let (field, value) = Self.prefixed(token) {
                add(field, value)
            } else {
                words.append(token)
            }
            i += 1
        }
    }

    private mutating func add(_ field: Field, _ value: String) {
        if field == .take {
            fields.append((field, Int(value).map(String.init) ?? value))
        } else {
            fields.append((field, TakeNaming.sanitize(value)))
        }
    }

    /// A slate value: starts with a digit (3, 12B, 04) – so words like "shot" or "stop" stay free words.
    private static func isValue(_ s: String) -> Bool { s.first?.isNumber == true }

    private static func prefixed(_ token: String) -> (Field, String)? {
        for (prefix, field) in prefixes where token.hasPrefix(prefix) {
            let value = String(token.dropFirst(prefix.count))
            if isValue(value) { return (field, value) }
        }
        return nil
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
