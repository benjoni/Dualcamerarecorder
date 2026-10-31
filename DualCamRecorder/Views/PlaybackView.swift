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
    @State private var exportingPDF = false
    /// Clip list search (scene, shot, take, file, cam clip, note, "good", "mos" …).
    @State private var searchText = ""
    /// While typing in the search field, single-key shortcuts (space, I, O, arrows) are switched off.
    @FocusState private var searchFocused: Bool
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
            if showCameraA {
                PlayerView(player: player.playerA)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .overlay { if settings.showWaveform { WaveformOverlay(model: player.waveformA) } }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            if showCameraB {
                PlayerView(player: player.playerB)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .overlay { if settings.showWaveform { WaveformOverlay(model: player.waveformB) } }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
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
                ShortcutButton(key: .leftArrow, modifiers: [.command]) { selectAdjacentClip(-1) }
                ShortcutButton(key: .rightArrow, modifiers: [.command]) { selectAdjacentClip(1) }
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
                    if showCameraA {
                        playerPane(title: "Camera A", role: .a, file: player.take?.camA, available: player.take?.camA != nil, content: PlayerView(player: player.playerA), waveform: player.waveformA)
                    }
                    if showCameraB {
                        playerPane(title: "Camera B", role: .b, file: player.take?.camB, available: player.take?.camB != nil, content: PlayerView(player: player.playerB), waveform: player.waveformB)
                    }
                }
                transport
                Spacer(minLength: 0)
            }
            .padding()
            .frame(minWidth: 700)
        }
        .animation(.easeInOut(duration: 0.2), value: showClipList)
    }

    /// Camera B is shown when the clip has a B file (or, with no clip loaded, in two-camera projects).
    private var showCameraB: Bool {
        if let take = player.take { return take.camB != nil }
        return settings.twoCameras
    }

    /// Camera A is hidden only for clips recorded with camera B alone.
    private var showCameraA: Bool {
        if let take = player.take { return take.camA != nil || take.camB == nil }
        return true
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
            .buttonStyle(BigButtonStyle())
            .font(.title3)

            Button {
                exportingPDF = true
            } label: {
                Label("Export PDF…", systemImage: "doc.richtext")
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .help("Clip report by shooting day, with pictures (⇧⌘P)")
            .disabled(library.takes.isEmpty)
            .sheet(isPresented: $exportingPDF) {
                ExportPDFSheet(library: library, settings: settings)
            }
            .buttonStyle(BigButtonStyle())
            .font(.title3)

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

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search scene, shot, take, file, note, good…", text: $searchText)
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
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.gray.opacity(0.15)))
            .padding(.horizontal, 8)
            .padding(.top, 8)
            if !searchText.isEmpty {
                Text("\(visibleTakes.count) of \(library.takes.count) clips")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.top, 4)
            }

            List(selection: $selection) {
                ForEach(TakeLibrary.group(visibleTakes)) { group in
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

    private func playerPane(title: String, role: CameraRole, file: URL?, available: Bool, content: PlayerView,
                            waveform: WaveformModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title3.weight(.bold))
            ZStack {
                content
                if available && settings.showWaveform {
                    WaveformOverlay(model: waveform)
                }
                if !available {
                    Text(player.take == nil ? "Select a clip" : "File missing").foregroundStyle(.secondary)
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack(spacing: 14) {
                Text(file?.lastPathComponent ?? " ")
                    .lineLimit(1).truncationMode(.middle)
                if let clip = player.slate?.cameraClip(role), !clip.isEmpty {
                    Text("Cam clip \(clip)")
                        .foregroundStyle(.primary)
                }
            }
            .font(.callout.monospaced()).foregroundStyle(.secondary)
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

            // Scene · shot · take in big letters above the transport buttons.
            if let slate = player.slate {
                Text(slate.shortLabel)
                    .font(.system(size: 34, weight: .bold))
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .padding(.top, 6)
            }

            // Buttons, one group under another; audio last.
            VStack(spacing: 10) {
                transportRow
                markRow
                audioButtons
            }
            .buttonStyle(BigButtonStyle())
            .font(.title2)
            .padding(.top, 4)
            .disabled(player.take == nil)

            // Info under the buttons.
            infoBlock
                .padding(.top, 6)

            // Good take + edit slate at the very bottom.
            HStack(spacing: 10) {
                SegmentGroup {
                    Toggle(isOn: Binding(
                        get: { player.slate?.good ?? false },
                        set: { good in
                            var slate = player.slate ?? SlateInfo()
                            slate.good = good
                            saveSlate(slate)
                        })) {
                        Label("Good take", systemImage: player.slate?.good == true ? "star.fill" : "star")
                    }
                    .help("Good (circled) take")
                }
                .toggleStyle(SegmentToggleStyle(width: 180, minHeight: 40))
                Button("Edit slate…") { editingSlate = true }
                    .buttonStyle(BigButtonStyle())
            }
            .font(.title2)
            .disabled(player.take == nil)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $editingSlate) {
            SlateEditSheet(slate: player.slate ?? SlateInfo(),
                           takeName: player.take?.name ?? "",
                           onSave: { saveSlate($0) })
        }
    }

    /// Stores the slate with the clip and rewrites CLIPLOG.CSV.
    private func saveSlate(_ slate: SlateInfo) {
        player.updateSlate(slate)
        if let folder = player.take?.folder {
            let names = settings.cameraNames
            DispatchQueue.global(qos: .utility).async { ClipLog.rebuild(folder: folder, names: names) }
        }
    }

    /// Prev · frame back · play · frame forward · Next.
    private var transportButtons: some View {
        HStack(spacing: 14) {
            Button { selectAdjacentClip(-1) } label: {
                Label("Prev", systemImage: "backward.end.alt.fill")
            }
            .keyboardShortcut(shortcut(.leftArrow, [.command]))
            .disabled(adjacentClip(-1) == nil)
            .help("Previous clip (⌘←)")

            Button { player.step(-1) } label: { Image(systemName: "backward.frame.fill") }
                .keyboardShortcut(shortcut(.leftArrow))
                .help("One frame back (←)")
            Button { player.togglePlay() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 160)
            }
            .keyboardShortcut(shortcut(.space))
            .help("Play / pause (space)")
            Button { player.step(1) } label: { Image(systemName: "forward.frame.fill") }
                .keyboardShortcut(shortcut(.rightArrow))
                .help("One frame forward (→)")

            Button { selectAdjacentClip(1) } label: {
                Label("Next", systemImage: "forward.end.alt.fill")
                    .labelStyle(TrailingIconLabelStyle())
            }
            .keyboardShortcut(shortcut(.rightArrow, [.command]))
            .disabled(adjacentClip(1) == nil)
            .help("Next clip (⌘→)")
        }
    }

    /// Transport buttons centered, speed at the right edge (an invisible copy on the left keeps them centered).
    private var transportRow: some View {
        HStack(spacing: 0) {
            speedControl.hidden()
            Spacer(minLength: 24)
            transportButtons
            Spacer(minLength: 24)
            speedControl
        }
    }

    private var speedControl: some View {
        HStack(spacing: 8) {
            Text("Speed").foregroundStyle(.secondary)
            SegmentGroup {
                ForEach([Float(0.5), 1, 2], id: \.self) { rate in
                    Toggle(rate == 0.5 ? "0.5×" : "\(Int(rate))×", isOn: Binding(
                        get: { player.rate == rate },
                        set: { if $0 { player.rate = rate } }))
                }
            }
            .toggleStyle(SegmentToggleStyle(width: 80, minHeight: 40))
        }
    }

    /// Keyboard shortcut that is off while the search field has the cursor.
    private func shortcut(_ key: KeyEquivalent, _ modifiers: EventModifiers = []) -> KeyboardShortcut? {
        searchFocused ? nil : KeyboardShortcut(key, modifiers: modifiers)
    }

    /// Clips shown in the list (all, or those matching the search).
    private var visibleTakes: [Take] {
        searchText.trimmingCharacters(in: .whitespaces).isEmpty ? library.takes : library.takes.filter { $0.matches(searchText) }
    }

    // MARK: - Previous / next clip (by clip number, i.e. recording order)

    private func adjacentClip(_ delta: Int) -> Take? {
        // While searching, Prev / Next step through the found clips only.
        let ordered = visibleTakes.sorted { $0.number < $1.number }
        guard let currentID = selection ?? player.take?.id,
              let index = ordered.firstIndex(where: { $0.id == currentID }) else {
            return delta > 0 ? ordered.first : ordered.last
        }
        let target = index + delta
        return ordered.indices.contains(target) ? ordered[target] : nil
    }

    private func selectAdjacentClip(_ delta: Int) {
        guard let take = adjacentClip(delta) else { return }
        selection = take.id
    }

    private var audioButtons: some View {
        SegmentGroup {
            if showCameraA {
                Toggle("Audio A", isOn: $player.audioA)
                    .help("Hear camera A")
            }
            if showCameraB {
                Toggle("Audio B", isOn: $player.audioB)
                    .help("Hear camera B")
            }
        }
        .toggleStyle(SegmentToggleStyle(minHeight: 40))
    }

    private var markButtons: some View {
        HStack(spacing: 10) {
            Button("Set IN") { player.setIn() }
                .keyboardShortcut(shortcut("i"))
                .help("IN at the current frame (I)")
            Button("Set OUT") { player.setOut() }
                .keyboardShortcut(shortcut("o"))
                .help("OUT at the current frame (O)")
            Button("Clear") { player.clearMarks() }
                .disabled(player.marks.isEmpty)
        }
    }

    /// IN/OUT buttons centered, loop at the right edge under the speed.
    private var markRow: some View {
        HStack(spacing: 0) {
            loopControl.hidden()
            Spacer(minLength: 24)
            markButtons
            Spacer(minLength: 24)
            loopControl
        }
    }

    /// "Loop" + No | IN/OUT | Clip, like the speed control.
    private var loopControl: some View {
        HStack(spacing: 8) {
            Text("Loop").foregroundStyle(.secondary)
            SegmentGroup {
                Toggle("NO", isOn: Binding(
                    get: { !player.loopInOut && !player.loopClip },
                    set: { if $0 { player.loopInOut = false; player.loopClip = false } }))
                    .help("Play once, to the end of the clip")
                Toggle("IN/OUT", isOn: $player.loopInOut)
                    .help("Repeat IN → OUT continuously (without OUT: to the end of the clip)")
                Toggle("CLIP", isOn: $player.loopClip)
                    .help("Repeat the whole clip from start to end (IN / OUT ignored)")
            }
            .toggleStyle(SegmentToggleStyle(width: 90, minHeight: 40))
        }
    }

    /// IN → OUT length; without IN from the start, without OUT to the end of the clip.
    private var markedDuration: Double? {
        let marks = player.marks
        guard marks.inPoint != nil || marks.outPoint != nil else { return nil }
        return max(0, (marks.outPoint ?? player.duration) - (marks.inPoint ?? 0))
    }

    /// IN/OUT times, slate summary and the A/B offset.
    private var infoBlock: some View {
        VStack(spacing: 4) {
            HStack(spacing: 10) {
                Text("IN \(player.marks.inPoint.map { player.timecode($0) } ?? "—")  ·  OUT \(player.marks.outPoint.map { player.timecode($0) } ?? "—")  ·  DUR \(markedDuration.map { player.timecode($0) } ?? "—")")
                    .font(.system(.title3, design: .monospaced))
                if let msg = player.marksMessage {
                    Text(msg).font(.callout).foregroundStyle(.red)
                }
            }
            if player.slate == nil && player.take != nil {
                Text("This clip has no slate data.")
            }
            // Shown only when A and B drift apart by more than one frame.
            if let offset = player.abOffsetMs, abs(offset) > 1000 * player.frameDuration.seconds {
                Label(String(format: "A/B out of sync: B−A %+.1f ms", offset), systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(Color.red)
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
    }
}
