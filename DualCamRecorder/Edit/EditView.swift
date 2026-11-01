//
//  EditView.swift
//  DualCamRecorder
//
//  Edit tab: the timeline built from Playback (⇧A / ⇧B), played as one movie,
//  pieces trimmed by their edges, moved by dragging, exported as MOV for the director.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct EditView: View {
    @ObservedObject var timeline: EditTimeline
    @ObservedObject var edit: EditPlayer
    var screensOnly = false

    @State private var selection: TimelineSegment.ID?
    @State private var zoom: Double = 1
    @AppStorage("editBurnIn") private var burnIn = true
    @State private var exportProgress: Float?
    @State private var exportResult: String?
    @State private var exportedURL: URL?

    var body: some View {
        Group {
            if screensOnly {
                PlayerView(player: edit.player)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .background { ShortcutButton(key: .space) { edit.togglePlay() } }
            } else {
                normalBody
            }
        }
        .task(id: timeline.segments) {
            // Short pause so a drag does not rebuild the movie on every step.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await edit.reload(segments: timeline.segments, folder: timeline.folder)
        }
        .onDisappear { edit.pause() }
    }

    private var normalBody: some View {
        VStack(spacing: 12) {
            PlayerView(player: edit.player)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay {
                    if timeline.segments.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "scissors").font(.largeTitle)
                            Text("The timeline is empty.").font(.title2.weight(.semibold))
                            Text("In Playback set IN / OUT and press + Camera A or + Camera B (⇧A / ⇧B).")
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Text(currentLabel)
                .font(.system(size: 30, weight: .bold))
                .lineLimit(1).minimumScaleFactor(0.6)

            transportRow
                .buttonStyle(BigButtonStyle())
                .font(.title2)
                .disabled(timeline.segments.isEmpty)

            selectedRow
                .buttonStyle(BigButtonStyle())
                .font(.title3)

            TimelineStrip(timeline: timeline, edit: edit, selection: $selection, zoom: zoom)
                .frame(height: 96)

            HStack(spacing: 10) {
                Text("Zoom").foregroundStyle(.secondary)
                Slider(value: $zoom, in: 1...20).frame(width: 220)
                Spacer()
                Text("\(timeline.segments.count) pieces · \(edit.timecode(timeline.totalDuration))")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .padding(.bottom, 20)   // room for the corner labels
        .background {
            ZStack {
                ShortcutButton(key: .space) { edit.togglePlay() }
                ShortcutButton(key: .leftArrow) { edit.step(-1) }
                ShortcutButton(key: .rightArrow) { edit.step(1) }
                ShortcutButton(key: .upArrow) { jumpPiece(-1) }
                ShortcutButton(key: .downArrow) { jumpPiece(1) }
                ShortcutButton(key: .leftArrow, modifiers: [.option]) { moveSelected(-1) }
                ShortcutButton(key: .rightArrow, modifiers: [.option]) { moveSelected(1) }
                ShortcutButton(key: .delete) { deleteSelected() }
                ShortcutButton(key: "z", modifiers: [.command]) { timeline.undo() }
            }
        }
    }

    /// Clip · scene · shot · take · camera of the piece under the playhead.
    private var currentLabel: String {
        guard let i = edit.pieceIndex(at: edit.currentTime), edit.pieces.indices.contains(i) else { return " " }
        let s = edit.pieces[i].segment
        return "\(s.label) · Camera \(s.cameraName)"
    }

    // MARK: - Transport + export

    private var transportRow: some View {
        HStack(spacing: 0) {
            exportControls.hidden()
            Spacer(minLength: 24)
            HStack(spacing: 14) {
                Text(edit.timecode(edit.currentTime))
                    .font(.system(.title2, design: .monospaced))
                    .frame(width: 170, alignment: .trailing)
                Button { jumpPiece(-1) } label: { Label("Prev", systemImage: "backward.end.alt.fill") }
                    .help("Start of this / previous piece (↑)")
                Button { edit.step(-1) } label: { Image(systemName: "backward.frame.fill") }
                    .help("One frame back (←)")
                Button { edit.togglePlay() } label: {
                    Image(systemName: edit.isPlaying ? "pause.fill" : "play.fill").frame(width: 160)
                }
                .help("Play / pause the whole edit (space)")
                Button { edit.step(1) } label: { Image(systemName: "forward.frame.fill") }
                    .help("One frame forward (→)")
                Button { jumpPiece(1) } label: {
                    Label("Next", systemImage: "forward.end.alt.fill").labelStyle(TrailingIconLabelStyle())
                }
                .help("Next piece (↓)")
                Text(edit.timecode(edit.duration))
                    .font(.system(.title2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 170, alignment: .leading)
            }
            Spacer(minLength: 24)
            exportControls
        }
    }

    private var exportControls: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 10) {
                Toggle("Clip info in picture", isOn: $burnIn)
                    .toggleStyle(.checkbox)
                    .font(.callout)
                    .help("Clip, scene, shot, take and camera in the bottom left corner of the exported movie")
                Button { export() } label: {
                    Label("Export MOV…", systemImage: "square.and.arrow.up").fixedSize()
                }
                .disabled(exportProgress != nil)
                .help("H.264 1080p movie of the whole edit, for the director")
            }
            if let exportProgress {
                ProgressView(value: Double(exportProgress)) {
                    Text("Exporting \(Int(exportProgress * 100)) %").font(.callout)
                }
                .frame(width: 240)
            } else if let exportResult {
                HStack(spacing: 8) {
                    Text(exportResult).font(.callout).foregroundStyle(exportedURL == nil ? .red : .green)
                        .lineLimit(1).truncationMode(.middle)
                    if let exportedURL {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([exportedURL]) }
                            .font(.callout)
                    }
                }
                .frame(maxWidth: 320, alignment: .trailing)
            }
        }
    }

    private func export() {
        guard let folder = timeline.folder, !timeline.segments.isEmpty else { return }
        edit.pause()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.directoryURL = folder
        panel.nameFieldStringValue = "\(folder.lastPathComponent)_EDIT.mov"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let segments = timeline.segments
        let burnIn = burnIn
        exportResult = nil
        exportedURL = nil
        exportProgress = 0
        Task { @MainActor in
            do {
                try await EditComposition.export(segments: segments, folder: folder, to: url, burnIn: burnIn) { p in
                    exportProgress = p
                }
                exportedURL = url
                exportResult = "Exported: \(url.lastPathComponent)"
            } catch {
                exportResult = error.localizedDescription
            }
            exportProgress = nil
        }
    }

    // MARK: - Selected piece

    private var selectedIndex: Int? {
        guard let selection else { return nil }
        return timeline.segments.firstIndex { $0.id == selection }
    }

    @ViewBuilder
    private var selectedRow: some View {
        if let i = selectedIndex {
            let s = timeline.segments[i]
            HStack(spacing: 12) {
                Text("\(i + 1).").foregroundStyle(.secondary)
                Text("Clip \(String(format: "%03d", s.take))").fontWeight(.semibold)
                SegmentGroup {
                    ForEach(CameraRole.allCases) { role in
                        Toggle(cameraTitle(s, role), isOn: Binding(
                            get: { s.camera == role },
                            set: { if $0 { timeline.setCamera(s.id, role) } }))
                            .disabled(!s.hasCamera(role))
                    }
                }
                .toggleStyle(SegmentToggleStyle(minHeight: 36))
                Text("IN \(edit.timecode(s.inPoint))  ·  OUT \(edit.timecode(s.outPoint))  ·  DUR \(edit.timecode(s.duration))")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button { moveSelected(-1) } label: { Image(systemName: "arrow.left") }
                    .disabled(i == 0)
                    .help("Move the piece earlier (⌥←)")
                Button { moveSelected(1) } label: { Image(systemName: "arrow.right") }
                    .disabled(i == timeline.segments.count - 1)
                    .help("Move the piece later (⌥→)")
                Button(role: .destructive) { deleteSelected() } label: { Label("Remove", systemImage: "trash") }
                    .help("Remove the piece from the timeline (⌫) – the recording stays")
                Button { timeline.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .disabled(!timeline.canUndo)
                    .help("Undo the last change (⌘Z)")
            }
        } else {
            HStack(spacing: 12) {
                Text(timeline.segments.isEmpty ? " " : "Click a piece to select it · drag it to move · drag its edges to trim")
                    .foregroundStyle(.secondary)
                Button { timeline.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .disabled(!timeline.canUndo)
                    .help("Undo the last change (⌘Z)")
            }
            .frame(minHeight: 44)
        }
    }

    private func cameraTitle(_ s: TimelineSegment, _ role: CameraRole) -> String {
        let file = role == .a ? s.fileA : s.fileB
        return "Camera " + (file.flatMap { TakeNaming.cameraName(in: $0) } ?? role.rawValue)
    }

    private func moveSelected(_ delta: Int) {
        guard let selection, let i = selectedIndex else { return }
        timeline.move(selection, to: i + delta)
    }

    private func deleteSelected() {
        guard let selection else { return }
        timeline.remove(selection)
        self.selection = nil
    }

    /// ↑ start of the current piece (or the previous one when already at its start), ↓ next piece.
    private func jumpPiece(_ delta: Int) {
        let pieces = edit.pieces
        guard !pieces.isEmpty else { return }
        let current = edit.pieceIndex(at: edit.currentTime) ?? 0
        var target = current + delta
        if delta < 0, edit.currentTime - pieces[current].start > 0.3 { target = current }
        target = min(max(0, target), pieces.count - 1)
        edit.pause()
        edit.seek(to: pieces[target].start)
    }
}

// MARK: - Timeline strip

/// Pieces as blocks (width = length), playhead, click to seek, drag to move, edges to trim.
struct TimelineStrip: View {
    @ObservedObject var timeline: EditTimeline
    @ObservedObject var edit: EditPlayer
    @Binding var selection: TimelineSegment.ID?
    var zoom: Double

    @State private var dragging: TimelineSegment.ID?
    @State private var dragOffset: CGFloat = 0
    @State private var trimStart: (inPoint: Double, outPoint: Double)?

    var body: some View {
        GeometryReader { geo in
            let total = max(timeline.totalDuration, 1)
            let pps = CGFloat(Double(geo.size.width - 24) / total * zoom)
            ScrollView(.horizontal) {
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(Color.gray.opacity(0.12))
                        .contentShape(Rectangle())
                        .onTapGesture(coordinateSpace: .local) { p in
                            edit.pause()
                            edit.seek(to: Double(p.x / pps))
                            selection = nil
                        }
                    let starts = timeline.starts
                    ForEach(Array(timeline.segments.enumerated()), id: \.element.id) { index, segment in
                        block(segment, pps: pps)
                            .offset(x: CGFloat(starts[index]) * pps + (dragging == segment.id ? dragOffset : 0), y: 8)
                            .zIndex(dragging == segment.id ? 1 : 0)
                    }
                    Rectangle()
                        .fill(Color.red)
                        .frame(width: 2)
                        .offset(x: CGFloat(edit.currentTime) * pps - 1)
                        .allowsHitTesting(false)
                }
                .frame(width: max(geo.size.width, CGFloat(total) * pps + 24), height: geo.size.height, alignment: .topLeading)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func color(_ role: CameraRole) -> Color {
        role == .a ? Color(red: 0.25, green: 0.36, blue: 0.62) : Color(red: 0.55, green: 0.38, blue: 0.18)
    }

    private func block(_ segment: TimelineSegment, pps: CGFloat) -> some View {
        let width = max(8, CGFloat(segment.duration) * pps)
        let selected = selection == segment.id
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(color(segment.camera))
            VStack(alignment: .leading, spacing: 2) {
                Text("Clip \(String(format: "%03d", segment.take))").font(.callout.weight(.bold))
                Text("Camera \(segment.cameraName)").font(.caption.weight(.semibold))
                Text(edit.timecode(segment.duration)).font(.caption.monospaced())
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(width: width, alignment: .leading)
            .clipped()
        }
        .frame(width: width, height: 80)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.white : Color.black.opacity(0.4), lineWidth: selected ? 3 : 1))
        .overlay(alignment: .leading) { trimHandle(segment, pps: pps, leading: true) }
        .overlay(alignment: .trailing) { trimHandle(segment, pps: pps, leading: false) }
        .contentShape(Rectangle())
        .onTapGesture {
            selection = segment.id
            if let i = timeline.segments.firstIndex(where: { $0.id == segment.id }) {
                edit.pause()
                edit.seek(to: timeline.starts[i])
            }
        }
        .gesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .global)
                .onChanged { value in
                    if dragging != segment.id {
                        dragging = segment.id
                        selection = segment.id
                    }
                    dragOffset = value.translation.width
                }
                .onEnded { _ in
                    drop(segment, pps: pps)
                    dragging = nil
                    dragOffset = 0
                }
        )
        .help("\(segment.label) · Camera \(segment.cameraName)")
    }

    /// New position: the dragged block goes before the first block whose middle is right of its middle.
    private func drop(_ segment: TimelineSegment, pps: CGFloat) {
        guard let from = timeline.segments.firstIndex(where: { $0.id == segment.id }) else { return }
        let starts = timeline.starts
        let middle = CGFloat(starts[from] + segment.duration / 2) * pps + dragOffset
        var target = 0
        for (i, other) in timeline.segments.enumerated() where other.id != segment.id {
            if CGFloat(starts[i] + other.duration / 2) * pps < middle { target += 1 }
        }
        timeline.move(segment.id, to: target)
    }

    private func trimHandle(_ segment: TimelineSegment, pps: CGFloat, leading: Bool) -> some View {
        Rectangle()
            .fill(Color.white.opacity(selection == segment.id ? 0.55 : 0.25))
            .frame(width: 8)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if trimStart == nil {
                            timeline.beginChange()
                            trimStart = (segment.inPoint, segment.outPoint)
                            selection = segment.id
                            edit.pause()
                        }
                        guard let start = trimStart else { return }
                        let delta = Double(value.translation.width / pps)
                        if leading {
                            timeline.trim(segment.id, inPoint: start.inPoint + delta)
                        } else {
                            timeline.trim(segment.id, outPoint: start.outPoint + delta)
                        }
                    }
                    .onEnded { _ in
                        trimStart = nil
                        timeline.commit()
                    }
            )
            .help(leading ? "Drag to move IN" : "Drag to move OUT")
    }
}
