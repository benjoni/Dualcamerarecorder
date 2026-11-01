//
//  EditClipList.swift
//  DualCamRecorder
//
//  Clip list of the Edit tab: every camera of a clip on its own row (Clip 014 · Camera A,
//  Clip 014 · Camera D), with search. + / double-click / ↵ adds the row to the end of the timeline –
//  IN → OUT when the clip has them, otherwise the whole clip.
//

import SwiftUI
import AVFoundation

struct EditClipList: View {
    @ObservedObject var library: TakeLibrary
    @ObservedObject var settings: AppSettings
    @ObservedObject var timeline: EditTimeline
    @ObservedObject var edit: EditPlayer
    @FocusState.Binding var searchFocused: Bool
    /// "Added to timeline: …" shown by the Edit tab.
    var onAdded: (String) -> Void

    @State private var searchText = ""
    @State private var selection: Set<String> = []

    /// One camera of one clip.
    struct Row: Identifiable {
        let take: Take
        let role: CameraRole
        let file: URL
        var id: String { "\(take.number)\(role.rawValue)" }
    }

    private var visibleTakes: [Take] {
        searchText.trimmingCharacters(in: .whitespaces).isEmpty ? library.takes : library.takes.filter { $0.matches(searchText) }
    }

    private func rows(_ takes: [Take]) -> [Row] {
        takes.flatMap { take in
            [take.camA.map { Row(take: take, role: .a, file: $0) },
             take.camB.map { Row(take: take, role: .b, file: $0) }].compactMap { $0 }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Clips").font(.headline)
                Spacer()
                Button { library.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh")
            }
            .padding(.horizontal, 10).padding(.top, 10)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search scene, shot, take, camera, note…", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { searchFocused = false }
                    .onExitCommand { searchFocused = false }
                if !searchText.isEmpty {
                    Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Clear search")
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.gray.opacity(0.15)))
            .padding(.horizontal, 8).padding(.top, 8)

            Text("+ / double-click / ↵ adds to the end of the timeline")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.top, 4)

            List(selection: $selection) {
                ForEach(TakeLibrary.group(visibleTakes)) { group in
                    Section(group.title) {
                        ForEach(rows(group.takes)) { row in
                            rowView(row).tag(row.id)
                        }
                    }
                }
            }
            .contextMenu(forSelectionType: String.self) { _ in
                EmptyView()
            } primaryAction: { ids in
                // Double-click or ↵ on the selected rows.
                let all = rows(visibleTakes)
                for id in ids.sorted() {
                    if let row = all.first(where: { $0.id == id }) { add(row) }
                }
            }
        }
        .onAppear { library.setFolder(settings.playbackFolderURL) }
        .onReceive(NotificationCenter.default.publisher(for: .takeFinished)) { _ in library.refresh() }
    }

    private func rowView(_ row: Row) -> some View {
        let take = row.take
        let name = take.cameraName(row.role, current: settings.cameraNames)
        return HStack(spacing: 8) {
            ClipCameraThumbnail(url: row.file, modified: take.modified)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("\(take.name) · Camera \(name)").font(.body.weight(.semibold)).foregroundStyle(.primary)
                    if take.slate?.good == true {
                        Image(systemName: "star.fill").foregroundStyle(.yellow).help("Good take")
                    }
                }
                if let slate = take.slate {
                    Text(slate.sceneShotTake).foregroundStyle(.primary)
                }
                if let m = take.marks, !m.isEmpty {
                    Label("IN \(m.inPoint.map { edit.timecode($0) } ?? "start") → OUT \(m.outPoint.map { edit.timecode($0) } ?? "end")",
                          systemImage: "flag.fill")
                        .labelStyle(.titleAndIcon)
                } else {
                    Text("Whole clip")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Button { add(row) } label: { Image(systemName: "plus.circle.fill").font(.title2) }
                .buttonStyle(.borderless)
                .help("Add to the end of the timeline")
        }
        .padding(.vertical, 2)
    }

    /// IN → OUT of the clip (only IN → to the end, only OUT → from the start), from this camera's file.
    private func add(_ row: Row) {
        let take = row.take
        Task { @MainActor in
            guard let length = try? await AVURLAsset(url: row.file).load(.duration).seconds, length > 0 else { return }
            let inPoint = min(take.marks?.inPoint ?? 0, length)
            let outPoint = min(take.marks?.outPoint ?? length, length)
            guard outPoint - inPoint >= EditTimeline.minimumLength else { return }
            let segment = TimelineSegment(take: take.number, camera: row.role,
                                          fileA: take.camA?.lastPathComponent, fileB: take.camB?.lastPathComponent,
                                          inPoint: inPoint, outPoint: outPoint, clipDuration: length,
                                          label: [take.name, take.slate?.shortLabel].compactMap { $0 }.joined(separator: " · "))
            timeline.append(segment)
            onAdded("Added to timeline: \(take.name) · Camera \(segment.cameraName) · \(edit.timecode(segment.duration))")
        }
    }
}

/// Picture from the middle of one camera's file.
private struct ClipCameraThumbnail: View {
    let url: URL
    let modified: Date
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Color.black)
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "film").foregroundStyle(.secondary)
            }
        }
        .frame(width: 96, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: url.path) {
            if let hit = ThumbnailCache.shared.cached(url: url, modified: modified) {
                image = hit
                return
            }
            image = await ThumbnailCache.shared.image(url: url, modified: modified)
        }
    }
}
