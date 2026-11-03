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
    @ObservedObject var library: TakeLibrary
    @ObservedObject var settings: AppSettings
    var screensOnly = false

    @AppStorage("editShowClips") private var showClipList = true
    @AppStorage("editShowSequences") private var showSequenceList = true
    /// While typing in the clip search, single-key shortcuts are off.
    @FocusState private var searchFocused: Bool
    @State private var addedMessage: String?
    @State private var addedMessageToken = 0

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
        HStack(spacing: 0) {
            if showClipList {
                EditClipList(library: library, settings: settings, timeline: timeline, edit: edit,
                             searchFocused: $searchFocused, onAdded: showAdded)
                    .frame(width: 340)
                    .padding(.bottom, 28)   // room for the corner label
                    .transition(.move(edge: .leading))
                Divider()
            }
            editArea
            if showSequenceList {
                Divider()
                EditSequenceList(timeline: timeline, edit: edit)
                    .frame(width: 260)
                    .padding(.bottom, 28)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showClipList)
        .animation(.easeInOut(duration: 0.2), value: showSequenceList)
    }

    private func showAdded(_ message: String) {
        addedMessageToken += 1
        let token = addedMessageToken
        addedMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if addedMessageToken == token { addedMessage = nil }
        }
    }

    private var editArea: some View {
        VStack(spacing: 12) {
            HStack {
                Button {
                    showClipList.toggle()
                } label: {
                    Label(showClipList ? "Hide clips" : "Clips", systemImage: "sidebar.left")
                }
                .keyboardShortcut("l", modifiers: [.command])
                .help("Show / hide the clip list (⌘L)")
                Spacer(minLength: 12)
                Label(timeline.currentSequence?.name ?? "", systemImage: "film.stack")
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 12)
                Button {
                    showSequenceList.toggle()
                } label: {
                    Label(showSequenceList ? "Hide sequences" : "Sequences", systemImage: "sidebar.right")
                }
                .keyboardShortcut("k", modifiers: [.command])
                .help("Show / hide the sequences – several cut passages (⌘K)")
            }
            .buttonStyle(BigButtonStyle())
            .font(.title3)

            PlayerView(player: edit.player)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay {
                    if timeline.segments.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "scissors").font(.largeTitle)
                            Text("The timeline is empty.").font(.title2.weight(.semibold))
                            Text("Add clips from the list (+, double-click, ↵) or in Playback with + Camera A / B (⇧A / ⇧B).")
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Text(currentLabel)
                .font(.system(size: 30, weight: .bold))
                .lineLimit(1).minimumScaleFactor(0.6)
                .overlay(alignment: .bottom) {
                    if let addedMessage {
                        Label(addedMessage, systemImage: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.green)
                            .padding(.horizontal, 12).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.85)))
                            .fixedSize()
                    }
                }

            transportRow
                .buttonStyle(BigButtonStyle())
                .font(.title2)
                .disabled(timeline.segments.isEmpty)

            selectedRow
                .buttonStyle(BigButtonStyle())
                .font(.title3)

            TimelineStrip(timeline: timeline, edit: edit, selection: $selection, zoom: zoom)
                .frame(height: 116)

            HStack(spacing: 10) {
                Text("Zoom").foregroundStyle(.secondary)
                Slider(value: $zoom, in: 1...20).frame(width: 140)
                Spacer(minLength: 12)
                VStack(spacing: 2) {
                    Text("\(edit.timecode(edit.currentTime)) / \(edit.timecode(edit.duration))")
                        .font(.system(.title3, design: .monospaced))
                    Text("\(timeline.segments.count) pieces").font(.callout).foregroundStyle(.secondary)
                }
                .fixedSize()
                Spacer(minLength: 12)
                exportControls
            }
        }
        .padding()
        .padding(.bottom, 20)   // room for the corner labels
        .background {
            if !searchFocused { editShortcuts }
        }
    }

    private var editShortcuts: some View {
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

    /// Clip · scene · shot · take · camera of the piece under the playhead.
    private var currentLabel: String {
        guard let i = edit.pieceIndex(at: edit.currentTime), edit.pieces.indices.contains(i) else { return " " }
        let s = edit.pieces[i].segment
        return "\(s.label) · Camera \(s.cameraName)"
    }

    // MARK: - Transport + export

    /// Prev · frame back · play · frame forward · Next (icons only, so the row fits next to the clip list).
    private var transportRow: some View {
        HStack(spacing: 14) {
            Button { jumpPiece(-1) } label: { Image(systemName: "backward.end.alt.fill") }
                .help("Start of this / previous piece (↑)")
            Button { edit.step(-1) } label: { Image(systemName: "backward.frame.fill") }
                .help("One frame back (←)")
            Button { edit.togglePlay() } label: {
                Image(systemName: edit.isPlaying ? "pause.fill" : "play.fill").frame(width: 140)
            }
            .help("Play / pause the whole edit (space)")
            Button { edit.step(1) } label: { Image(systemName: "forward.frame.fill") }
                .help("One frame forward (→)")
            Button { jumpPiece(1) } label: { Image(systemName: "forward.end.alt.fill") }
                .help("Next piece (↓)")
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
        let sequence = (timeline.currentSequence?.name ?? "EDIT").replacingOccurrences(of: "/", with: "-")
        panel.nameFieldStringValue = "\(folder.lastPathComponent)_\(sequence).mov"
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
            VStack(spacing: 8) {
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
                    .fixedSize()
            }
            HStack(spacing: 12) {
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
            }
        } else {
            VStack(spacing: 8) {
                Text(timeline.segments.isEmpty ? " " : "Click a piece to select it · drag it to move · drag its edges to trim")
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 36)
                Button { timeline.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .disabled(!timeline.canUndo)
                    .help("Undo the last change (⌘Z)")
            }
        }
    }

    private func cameraTitle(_ s: TimelineSegment, _ role: CameraRole) -> String {
        let file = role == .a ? s.fileA : s.fileB
        return "Camera " + (file.flatMap { TakeNaming.cameraName(in: $0) } ?? role.rawValue)
    }

    private func moveSelected(_ delta: Int) {
        guard let selection, let i = selectedIndex else { return }
        timeline.move(selection, to: i + delta)
        edit.seekToStart(of: selection, in: timeline)
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

/// Pieces as blocks (width = length), playhead, click to seek, drag to move, edges to trim. The playhead is
/// moved with the mouse on the ruler above the blocks, by its handle, or on the empty part of the strip.
struct TimelineStrip: View {
    @ObservedObject var timeline: EditTimeline
    @ObservedObject var edit: EditPlayer
    @Binding var selection: TimelineSegment.ID?
    var zoom: Double

    @State private var dragging: TimelineSegment.ID?
    @State private var dragOffset: CGFloat = 0
    @State private var trimStart: (inPoint: Double, outPoint: Double)?
    /// The playhead is being dragged with the mouse.
    @State private var scrubbing = false

    private static let rulerHeight: CGFloat = 20
    private static let space = "timelineContent"

    var body: some View {
        GeometryReader { geo in
            let total = max(timeline.totalDuration, 1)
            let pps = CGFloat(Double(geo.size.width - 24) / total * zoom)
            ScrollView(.horizontal) {
                ZStack(alignment: .topLeading) {
                    // Empty part of the strip: click or drag moves the playhead.
                    Rectangle()
                        .fill(Color.gray.opacity(0.12))
                        .contentShape(Rectangle())
                        .gesture(scrubGesture(pps: pps, deselect: true))
                    ruler(total: total, pps: pps)
                    let starts = timeline.starts
                    ForEach(Array(timeline.segments.enumerated()), id: \.element.id) { index, segment in
                        block(segment, pps: pps)
                            .offset(x: CGFloat(starts[index]) * pps + (dragging == segment.id ? dragOffset : 0),
                                    y: Self.rulerHeight + 6)
                            .zIndex(dragging == segment.id ? 1 : 0)
                    }
                    playhead(height: geo.size.height, pps: pps)
                        .offset(x: CGFloat(edit.currentTime) * pps - 7)
                        .zIndex(2)
                }
                .frame(width: max(geo.size.width, CGFloat(total) * pps + 24), height: geo.size.height, alignment: .topLeading)
                .coordinateSpace(name: Self.space)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Click or drag (anywhere along the strip) puts the playhead under the mouse.
    private func scrubGesture(pps: CGFloat, deselect: Bool = false) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if !scrubbing {
                    scrubbing = true
                    edit.pause()
                    if deselect { selection = nil }
                }
                edit.scrub(to: Double(max(0, value.location.x) / pps))
            }
            .onEnded { value in
                scrubbing = false
                edit.seek(to: min(edit.duration, Double(max(0, value.location.x) / pps)))
            }
    }

    /// Time ruler above the blocks with a mark every second (every 5 / 10 s when zoomed out).
    private func ruler(total: Double, pps: CGFloat) -> some View {
        let step: Double = pps >= 40 ? 1 : (pps >= 8 ? 5 : 10)
        return Canvas { context, size in
            var t = 0.0
            while t <= total + step {
                let x = CGFloat(t) * pps
                let major = Int(t.rounded()) % Int(step * 5) == 0
                context.fill(Path(CGRect(x: x, y: size.height - (major ? 10 : 5), width: 1, height: major ? 10 : 5)),
                             with: .color(.secondary.opacity(0.7)))
                if major {
                    let s = Int(t.rounded())
                    context.draw(Text(String(format: "%d:%02d", s / 60, s % 60)).font(.caption2.monospacedDigit())
                                    .foregroundColor(.secondary),
                                 at: CGPoint(x: x + 3, y: 1), anchor: .topLeading)
                }
                t += step
            }
        }
        .frame(height: Self.rulerHeight)
        .background(Color.black.opacity(0.35))
        .contentShape(Rectangle())
        .gesture(scrubGesture(pps: pps))
        .onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .help("Click or drag to move the playhead")
    }

    /// Red playhead with a handle on the ruler – drag it to any place, also over the pieces.
    private func playhead(height: CGFloat, pps: CGFloat) -> some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(Color.red)
                .frame(width: 2, height: height)
            Path { p in
                p.move(to: CGPoint(x: 0, y: 0))
                p.addLine(to: CGPoint(x: 14, y: 0))
                p.addLine(to: CGPoint(x: 14, y: 10))
                p.addLine(to: CGPoint(x: 7, y: 17))
                p.addLine(to: CGPoint(x: 0, y: 10))
                p.closeSubpath()
            }
            .fill(Color.red)
            .frame(width: 14, height: 17)
        }
        .frame(width: 14, height: height)
        .contentShape(Rectangle())
        .gesture(scrubGesture(pps: pps))
        .onHover { inside in
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .help("Drag to move the playhead")
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
            HStack(alignment: .top, spacing: 8) {
                SegmentThumbnail(url: timeline.url(for: segment), seconds: (segment.inPoint + segment.outPoint) / 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clip \(String(format: "%03d", segment.take))").font(.callout.weight(.bold))
                    Text("Camera \(segment.cameraName)").font(.caption.weight(.semibold))
                    Text(edit.timecode(segment.duration)).font(.caption.monospaced())
                }
                .foregroundStyle(.white)
                .fixedSize()
            }
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
        edit.seekToStart(of: segment.id, in: timeline)
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

/// Picture from the middle of a piece (from the camera the piece uses).
private struct SegmentThumbnail: View {
    let url: URL?
    let seconds: Double
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
        .frame(width: 120, height: 68)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: "\(url?.path ?? "")|\(Int(seconds * 10))") {
            guard let url else { image = nil; return }
            image = await ThumbnailCache.shared.image(url: url, at: seconds)
        }
    }
}
