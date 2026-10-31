//
//  PlaybackView.swift
//  DualCamRecorder
//

import SwiftUI

struct PlaybackView: View {
    @ObservedObject var library: TakeLibrary
    @ObservedObject var player: SyncPlaybackController
    @ObservedObject var settings: AppSettings
    @State private var selection: Take.ID?
    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false
    @State private var editingSlate = false
    /// Clip list is hidden by default – opened with the "Clips" button (⌘L) and hidden again by the user.
    @State private var showClipList = false
    /// Set when the tab appears: select the most recent clip as soon as the list is (re)loaded.
    @State private var selectLatestPending = false

    var body: some View {
        HStack(spacing: 0) {
            if showClipList {
                takeList
                    .frame(width: 340)
                    .transition(.move(edge: .leading))
                Divider()
            }
            VStack(spacing: 12) {
                header
                HStack(spacing: 12) {
                    playerPane(title: "Camera A", file: player.take?.camA, available: player.take?.camA != nil, content: PlayerView(player: player.playerA))
                    playerPane(title: "Camera B", file: player.take?.camB, available: player.take?.camB != nil, content: PlayerView(player: player.playerB))
                }
                transport
                Spacer(minLength: 0)
            }
            .padding()
            .frame(minWidth: 700)
        }
        .animation(.easeInOut(duration: 0.2), value: showClipList)
        .onAppear {
            // Switching to Playback always cues the latest recorded clip.
            selectLatestPending = true
            library.setFolder(settings.playbackFolderURL)
            selectLatest()
            // Stop waiting for a re-scan after a moment, so later folder changes do not jump the selection.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { selectLatestPending = false }
        }
        .onDisappear { selectLatestPending = false }
        .onChange(of: settings.playbackFolderURL) { _, url in
            selectLatestPending = true
            library.setFolder(url)
        }
        .onChange(of: library.takes) { _, _ in
            if selectLatestPending {
                selectLatest()
                selectLatestPending = false
            }
        }
        .onChange(of: selection) { _, id in
            player.load(library.takes.first { $0.id == id })
        }
        .onChange(of: player.currentTime) { _, t in
            if !isScrubbing { scrubValue = t }
        }
        .onReceive(NotificationCenter.default.publisher(for: .takeFinished)) { _ in library.refresh() }
    }

    /// Newest clip = first in the list (sorted by clip number, descending).
    private func selectLatest() {
        guard let latest = library.takes.first else { return }
        if selection != latest.id {
            selection = latest.id
        } else if player.take?.id != latest.id {
            player.load(latest)
        }
    }

    /// Clip list toggle + what is loaded.
    private var header: some View {
        HStack(spacing: 12) {
            Button {
                showClipList.toggle()
            } label: {
                Label(showClipList ? "Hide clips" : "Clips", systemImage: "sidebar.left")
            }
            .keyboardShortcut("l", modifiers: [.command])
            .help("Show / hide the clip list (⌘L)")

            if let take = player.take {
                Text(take.name).font(.headline)
                if let slate = take.slate {
                    Text(slate.shortLabel).foregroundStyle(.secondary)
                }
                if take.id == library.takes.first?.id {
                    Badge(text: "LATEST", color: .blue)
                }
            } else {
                Text(library.takes.isEmpty ? "No clips in this folder yet." : "No clip selected.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var takeList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Clips").font(.headline)
                Spacer()
                Button { library.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh list")
            }
            .padding(8)
            Text(library.folder?.path ?? "")
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .padding(.horizontal, 8)
            List(library.takes, selection: $selection) { take in
                HStack(spacing: 8) {
                    TakeThumbnail(take: take)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(take.name).font(.body.weight(.semibold)).foregroundStyle(.primary)
                            if take.slate?.good == true {
                                Image(systemName: "star.fill").foregroundStyle(.yellow).help("Good take")
                            }
                            if let m = take.marks, !m.isEmpty {
                                Image(systemName: "flag.fill").foregroundStyle(.yellow).help("Has IN/OUT")
                            }
                        }
                        if let slate = take.slate {
                            Text(slate.shortLabel).foregroundStyle(.primary)
                        }
                        HStack(spacing: 6) {
                            Text(take.camA != nil ? "A" : "–").foregroundStyle(take.camA != nil ? Color.green : Color.secondary)
                            Text(take.camB != nil ? "B" : "–").foregroundStyle(take.camB != nil ? Color.green : Color.secondary)
                            Text(DisplayFormat.bytes(take.sizeBytes))
                        }
                        HStack(spacing: 4) {
                            Text(take.modified, style: .date)
                            Text(take.modified, style: .time)
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .tag(take.id)
            }
        }
    }

    private func playerPane(title: String, file: URL?, available: Bool, content: PlayerView) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title3.weight(.bold))
            ZStack {
                content
                if !available {
                    Text(player.take == nil ? "Select a clip" : "File missing").foregroundStyle(.secondary)
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(file?.lastPathComponent ?? " ")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity)
    }

    /// Thin bar under the slider showing the IN–OUT range.
    private var rangeBar: some View {
        GeometryReader { geo in
            let d = max(player.duration, 0.001)
            let lo = CGFloat((player.marks.inPoint ?? 0) / d)
            let hi = CGFloat((player.marks.outPoint ?? d) / d)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                if !player.marks.isEmpty {
                    Capsule().fill(Color.yellow.opacity(0.8))
                        .frame(width: max(2, (hi - lo) * geo.size.width))
                        .offset(x: lo * geo.size.width)
                }
            }
        }
        .frame(height: 4)
        .padding(.horizontal, 110)
    }

    /// Slate summary of the loaded take + edit button.
    private var slateInfo: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "film.stack")
            if let slate = player.slate {
                Text(slate.shortLabel).font(.headline).fixedSize()
                Text(slate.longDescription.replacingOccurrences(of: "\n", with: "  ·  "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            } else {
                Text("This clip has no slate data.").foregroundStyle(.secondary)
            }
            Spacer()
            Button("Slate…") { editingSlate = true }
                .disabled(player.take == nil)
        }
        .sheet(isPresented: $editingSlate) {
            SlateEditSheet(slate: player.slate ?? SlateInfo(),
                           takeName: player.take?.name ?? "",
                           onSave: { player.updateSlate($0) })
        }
    }

    private var markControls: some View {
        HStack(spacing: 10) {
            Button("Set IN") { player.setIn() }
                .keyboardShortcut("i", modifiers: [])
                .help("IN at the current frame (I)")
            Button("Set OUT") { player.setOut() }
                .keyboardShortcut("o", modifiers: [])
                .help("OUT at the current frame (O)")
            Button { player.goToIn() } label: { Label("Go to IN", systemImage: "arrow.left.to.line") }
                .disabled(player.marks.inPoint == nil)
            Button { player.goToOut() } label: { Label("Go to OUT", systemImage: "arrow.right.to.line") }
                .disabled(player.marks.outPoint == nil)
            Button("Clear") { player.clearMarks() }
                .disabled(player.marks.isEmpty)
            Toggle("Play IN–OUT only", isOn: $player.limitToRange)
            Spacer()
            Text("IN \(player.marks.inPoint.map { player.timecode($0) } ?? "—")  ·  OUT \(player.marks.outPoint.map { player.timecode($0) } ?? "—")")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
            if let msg = player.marksMessage {
                Text(msg).font(.caption).foregroundStyle(.red)
            }
        }
        .disabled(player.take == nil)
    }

    private var transport: some View {
        VStack(spacing: 8) {
            HStack {
                Text(player.timecode(isScrubbing ? scrubValue : player.currentTime))
                    .font(.system(.title3, design: .monospaced))
                Slider(value: $scrubValue, in: 0...max(player.duration, 0.001), onEditingChanged: { editing in
                    isScrubbing = editing
                    player.isScrubbing = editing
                    if !editing { player.seek(seconds: scrubValue) }
                })
                .onChange(of: scrubValue) { _, v in
                    if isScrubbing { player.seek(seconds: v) }
                }
                Text(player.timecode(player.duration))
                    .font(.system(.title3, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            rangeBar
            markControls
            slateInfo
            HStack(spacing: 14) {
                Button { player.goToStart() } label: { Image(systemName: "backward.end.fill") }
                    .help("Go to start")
                Button { player.step(-1) } label: { Image(systemName: "backward.frame.fill") }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .help("One frame back (←)")
                Button { player.togglePlay() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 40)
                }
                .keyboardShortcut(.space, modifiers: [])
                .help("Play / pause (space)")
                Button { player.step(1) } label: { Image(systemName: "forward.frame.fill") }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .help("One frame forward (→)")

                Picker("Speed", selection: $player.rate) {
                    Text("0.5×").tag(Float(0.5))
                    Text("1×").tag(Float(1.0))
                }
                .pickerStyle(.segmented)
                .frame(width: 140)

                Toggle("Audio A", isOn: $player.audioA)
                Toggle("Audio B", isOn: $player.audioB)

                Spacer()
                if let offset = player.abOffsetMs {
                    Text(String(format: "Offset B−A: %+.1f ms", offset))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(abs(offset) > 1000 * player.frameDuration.seconds ? .red : .secondary)
                }
            }
            .disabled(player.take == nil)
        }
    }
}
