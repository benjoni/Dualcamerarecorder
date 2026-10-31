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

    var id: Int { number }
    var name: String { TakeNaming.displayName(take: number) }
}

final class TakeLibrary: ObservableObject {
    @Published private(set) var takes: [Take] = []
    @Published private(set) var folder: URL?

    /// Take numbers currently being recorded into this folder – hidden until finished.
    var excludedTake: () -> Int? = { nil }

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
        scanQueue.async {
            let found = Self.scan(folder, excluding: excluded)
            DispatchQueue.main.async {
                if self.folder == folder { self.takes = found }
            }
        }
    }

    private static func scan(_ folder: URL, excluding excluded: Int?) -> [Take] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                      options: [.skipsHiddenFiles]) else { return [] }
        var byNumber: [Int: Take] = [:]
        for url in urls {
            guard let parsed = TakeNaming.parse(url.lastPathComponent), parsed.take != excluded else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let date = values?.contentModificationDate ?? .distantPast
            let size = Int64(values?.fileSize ?? 0)
            var take = byNumber[parsed.take] ?? Take(number: parsed.take, camA: nil, camB: nil, modified: date, sizeBytes: 0)
            if parsed.role == .a { take.camA = url } else { take.camB = url }
            take.modified = max(take.modified, date)
            take.sizeBytes += size
            byNumber[parsed.take] = take
        }
        return byNumber.values.sorted { $0.number > $1.number }
    }

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
