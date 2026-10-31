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

    /// Only the two players, nothing else (toggled with ⌘F).
    var screensOnly = false

    var body: some View {
        Group {
            if screensOnly {
                screensOnlyBody
            } else {
                normalBody
            }
        }
        .onAppear {
            library.setFolder(settings.playbackFolderURL)
            if library.cueLatestOnShow {
                // Switching to the Playback tab cues the latest recorded clip.
                library.cueLatestOnShow = false
                selectLatestPending = true
                selectLatest()
                // Stop waiting for a re-scan after a moment, so later folder changes do not jump the selection.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { selectLatestPending = false }
            } else if selection == nil {
                // View re-created (e.g. "screens only" toggled) – keep the clip that is loaded.
                selection = player.take?.id
            }
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
            // Do not reload (and lose the position) when the same clip is re-selected.
            guard id != player.take?.id else { return }
            player.load(library.takes.first { $0.id == id })
        }
        .onChange(of: player.currentTime) { _, t in
            if !isScrubbing { scrubValue = t }
        }
        .onReceive(NotificationCenter.default.publisher(for: .takeFinished)) { _ in library.refresh() }
    }

    /// Both players filling the window; transport shortcuts keep working.
    private var screensOnlyBody: some View {
        HStack(spacing: 8) {
            PlayerView(player: player.playerA)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            PlayerView(player: player.playerB)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .background {
            ZStack {
                ShortcutButton(key: .space) { player.togglePlay() }
                ShortcutButton(key: .leftArrow) { player.step(-1) }
                ShortcutButton(key: .rightArrow) { player.step(1) }
                ShortcutButton(key: "i") { player.setIn() }
                ShortcutButton(key: "o") { player.setOut() }
            }
        }
    }

    private var normalBody: some View {
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
    }

    /// Newest clip = first in the list (sorted by clip number, descending).
    private func selectLatest() {
        guard let latest = library.latestTake else { return }
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
                if take.id == library.latestTake?.id {
                    Badge(text: "LATEST", color: .blue)
                }
            } else {
                Text(library.takes.isEmpty ? "No clips in this folder yet." : "No clip selected.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
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
            List(selection: $selection) {
                ForEach(library.groupedByShootingDay) { group in
                    Section(group.title) {
                        ForEach(group.takes) { take in
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
                                        Text(slate.sceneShotTake).foregroundStyle(.primary)
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
                .font(.callout.monospaced()).foregroundStyle(.secondary)
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
        .frame(height: 5)
        .padding(.horizontal, 130)
    }

    // MARK: - Controls: all buttons stacked, info below

    private var transport: some View {
        VStack(spacing: 8) {
            HStack {
                Text(player.timecode(isScrubbing ? scrubValue : player.currentTime))
                    .font(.system(.title2, design: .monospaced))
                Slider(value: $scrubValue, in: 0...max(player.duration, 0.001), onEditingChanged: { editing in
                    isScrubbing = editing
                    player.isScrubbing = editing
                    if !editing { player.seek(seconds: scrubValue) }
                })
                .onChange(of: scrubValue) { _, v in
                    if isScrubbing { player.seek(seconds: v) }
                }
                Text(player.timecode(player.duration))
                    .font(.system(.title2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            rangeBar

            // Buttons, one group under another; audio last.
            VStack(spacing: 10) {
                transportButtons
                markButtons
                audioButtons
            }
            .controlSize(.large)
            .font(.title3)
            .padding(.top, 4)
            .disabled(player.take == nil)

            // Info under the buttons.
            infoBlock
                .padding(.top, 6)

            // Edit slate at the very bottom.
            Button("Edit slate…") { editingSlate = true }
                .controlSize(.large)
                .font(.title3)
                .disabled(player.take == nil)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $editingSlate) {
            SlateEditSheet(slate: player.slate ?? SlateInfo(),
                           takeName: player.take?.name ?? "",
                           onSave: { player.updateSlate($0) })
        }
    }

    private var transportButtons: some View {
        HStack(spacing: 14) {
            Button { player.goToStart() } label: { Image(systemName: "backward.end.fill") }
                .help("Go to start")
            Button { player.step(-1) } label: { Image(systemName: "backward.frame.fill") }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .help("One frame back (←)")
            Button { player.togglePlay() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 56)
            }
            .keyboardShortcut(.space, modifiers: [])
            .help("Play / pause (space)")
            Button { player.step(1) } label: { Image(systemName: "forward.frame.fill") }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .help("One frame forward (→)")

            Picker("Speed", selection: $player.rate) {
                Text("0.5×").tag(Float(0.5))
                Text("1×").tag(Float(1.0))
                Text("2×").tag(Float(2.0))
            }
            .pickerStyle(.segmented)
            .frame(width: 240)
        }
    }

    private var audioButtons: some View {
        HStack(spacing: 14) {
            Toggle("Audio A", isOn: $player.audioA)
            Toggle("Audio B", isOn: $player.audioB)
        }
    }

    private var markButtons: some View {
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
            SegmentGroup {
                Toggle("Play IN–OUT only", isOn: $player.limitToRange)
                    .help("Start at IN and stop at OUT")
                Toggle("Loop IN/OUT", isOn: $player.loopInOut)
                    .help("Repeat IN → OUT continuously (without OUT: to the end of the clip)")
            }
            .toggleStyle(SegmentToggleStyle())
        }
    }

    /// IN/OUT times, slate summary and the A/B offset.
    private var infoBlock: some View {
        VStack(spacing: 4) {
            HStack(spacing: 10) {
                Text("IN \(player.marks.inPoint.map { player.timecode($0) } ?? "—")  ·  OUT \(player.marks.outPoint.map { player.timecode($0) } ?? "—")")
                    .font(.system(.title3, design: .monospaced))
                if let msg = player.marksMessage {
                    Text(msg).font(.callout).foregroundStyle(.red)
                }
            }
            if let slate = player.slate {
                HStack(spacing: 6) {
                    Image(systemName: "film.stack")
                    Text(slate.shortLabel).font(.title2.weight(.semibold))
                }
                Text(slate.longDescription.replacingOccurrences(of: "\n", with: "  ·  "))
                    .font(.body).lineLimit(2)
                    .multilineTextAlignment(.center)
            } else if player.take != nil {
                Text("This clip has no slate data.")
            }
            if let offset = player.abOffsetMs {
                Text(String(format: "Offset B−A: %+.1f ms", offset))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(abs(offset) > 1000 * player.frameDuration.seconds ? Color.red : Color.secondary)
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
    }
}
