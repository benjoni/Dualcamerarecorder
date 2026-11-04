//
//  PlaybackView.swift
//  DualCamRecorder
//

import SwiftUI

struct PlaybackView: View {
    @ObservedObject var library: TakeLibrary
    @ObservedObject var player: SyncPlaybackController
    @ObservedObject var settings: AppSettings
    @ObservedObject var timeline: EditTimeline
    @State private var selection: Take.ID?
    /// "Added to timeline: …" for a moment after ⇧A / ⇧B.
    @State private var addedMessage: String?
    @State private var addedMessageToken = 0
    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false
    @State private var editingSlate = false
    /// Clip waiting for "Move to Trash" in the confirmation.
    @State private var deletingTake: Take?
    @State private var deleteError: String?
    /// Clip list search (scene, shot, take, file, cam clip, note, "good", "mos" …).
    @State private var searchText = ""
    /// While typing in the search field, single-key shortcuts (space, I, O, arrows) are switched off.
    @FocusState private var searchFocused: Bool
    /// Clip list is hidden by default – opened with the "Clips" button (⌘L) and hidden again by the user.
    #if DEBUG
    @State private var showClipList = UserDefaults.standard.bool(forKey: "snapshotShowClips")   // -snapshotShowClips YES
    #else
    @State private var showClipList = false
    #endif
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
                    .overlay { FrameMaskOverlay(mask: settings.maskA) }
                    .overlay { if settings.showWaveform { WaveformOverlay(model: player.waveformA) } }
                    .overlay { timecodeBadge(.a) }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            if showCameraB {
                PlayerView(player: player.playerB)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .overlay { FrameMaskOverlay(mask: settings.maskB) }
                    .overlay { if settings.showWaveform { WaveformOverlay(model: player.waveformB) } }
                    .overlay { timecodeBadge(.b) }
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
                ShortcutButton(key: .upArrow) { selectAdjacentClip(-1) }
                ShortcutButton(key: .downArrow) { selectAdjacentClip(1) }
                ShortcutButton(key: "a", modifiers: [.shift]) { addToTimeline(.a) }
                ShortcutButton(key: "b", modifiers: [.shift]) { addToTimeline(.b) }
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
            VStack(spacing: 8) {
                header
                Spacer(minLength: 0)
                HStack(alignment: .top, spacing: 8) {
                    if showCameraA {
                        playerPane(title: "Camera \(player.take?.cameraName(.a, current: settings.cameraNames) ?? settings.cameraNames.a)", role: .a, file: player.take?.camA, available: player.take?.camA != nil, content: PlayerView(player: player.playerA), waveform: player.waveformA)
                    }
                    if showCameraB {
                        playerPane(title: "Camera \(player.take?.cameraName(.b, current: settings.cameraNames) ?? settings.cameraNames.b)", role: .b, file: player.take?.camB, available: player.take?.camB != nil, content: PlayerView(player: player.playerB), waveform: player.waveformB)
                    }
                }
                .layoutPriority(1)   // screens first; the controls follow right under them, spare room above and below
                transport
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
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
            .buttonStyle(BigButtonStyle(small: true))   // same size as the audio buttons
            .font(.callout)

            if player.take == nil {
                Text(library.takes.isEmpty ? "No clips in this folder yet." : "No clip selected.")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            // Clip · day · scene · shot · take in big letters.
            if let take = player.take {
                Text([take.name, player.slate?.shortLabel].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 28, weight: .bold))
                    .lineLimit(1).minimumScaleFactor(0.6)
                if player.slate?.rehearsal == true {
                    Text("REHEARSAL")
                        .font(.title3.weight(.bold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color.orange.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(.black)
                        .help("Recorded only by the app – the cameras did not record")
                }
                if take.id == library.latestTake?.id {
                    Text("LATEST")
                        .font(.title3.weight(.bold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color.blue.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(.white)
                }
            }
            Spacer(minLength: 0)
            // Invisible copy of the Clips button keeps the title centered.
            Label(showClipList ? "Hide clips" : "Clips", systemImage: "sidebar.left")
                .font(.title3).padding(.horizontal, 16).hidden()
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
                                        if take.slate?.rehearsal == true {
                                            Text("REH").font(.caption2.weight(.bold))
                                                .padding(.horizontal, 4).padding(.vertical, 1)
                                                .background(Color.orange, in: RoundedRectangle(cornerRadius: 3))
                                                .foregroundStyle(.black)
                                                .help("Rehearsal – recorded only by the app")
                                        }
                                        if let m = take.marks, !m.isEmpty {
                                            Image(systemName: "flag.fill").foregroundStyle(.yellow).help("Has IN/OUT")
                                        }
                                    }
                                    if let slate = take.slate {
                                        Text(slate.sceneShotTake).foregroundStyle(.primary)
                                    }
                                    HStack(spacing: 6) {
                                        Text(take.camA != nil ? take.cameraName(.a, current: settings.cameraNames) : "–").foregroundStyle(take.camA != nil ? Color.green : Color.secondary)
                                        Text(take.camB != nil ? take.cameraName(.b, current: settings.cameraNames) : "–").foregroundStyle(take.camB != nil ? Color.green : Color.secondary)
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
                            .contextMenu {
                                Button("Move to Trash…", role: .destructive) { deletingTake = take }
                            }
                        }
                    }
                }
            }
        }
    }

    private func playerPane(title: String, role: CameraRole, file: URL?, available: Bool, content: PlayerView,
                            waveform: WaveformModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(title).font(.title3.weight(.bold))
                FrameMaskButton(settings: settings, role: role)
            }
            ZStack {
                content
                if available { FrameMaskOverlay(mask: settings.mask(role)) }
                if available && settings.showWaveform {
                    WaveformOverlay(model: waveform)
                }
                if available { timecodeBadge(role) }
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
            // Timecode and camera settings lines are always there (empty when missing) – both screens the same size.
            Group {
                if available, let tc = player.timecodeRange(role) {
                    // Camera timecode at the play position, and of the file's first / last frame.
                    HStack(spacing: 14) {
                        Text("TC " + tc.at(seconds: isScrubbing ? scrubValue : player.currentTime,
                                           frameDuration: player.frameDuration.seconds).string)
                            .foregroundStyle(.primary).fontWeight(.semibold)
                        Text("IN \(tc.start.string)  ·  OUT \(tc.end.string)")
                    }
                    .textSelection(.enabled)
                    .help("Camera timecode (from the SDI signal) – the file has it as its timecode track")
                } else {
                    Text(" ")
                }
            }
            .font(.callout.monospaced()).foregroundStyle(.secondary)
            .lineLimit(1)
            let setup = (player.slate?.setup(role)).flatMap { $0.isEmpty ? nil : $0 }
            Text(setup.map(\.summary) ?? " ")
                .font(.callout).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
                .textSelection(.enabled)
                .help(setup?.summary ?? "")
        }
        .frame(maxWidth: .infinity)
    }

    /// Camera timecode at the play position in the picture's corner, like on the Record tab.
    @ViewBuilder
    private func timecodeBadge(_ role: CameraRole) -> some View {
        if let tc = player.timecodeRange(role) {
            Text(tc.at(seconds: isScrubbing ? scrubValue : player.currentTime,
                       frameDuration: player.frameDuration.seconds).string)
                .font(.system(.title3, design: .monospaced).weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .allowsHitTesting(false)
        }
    }

    /// Thin bar under the slider showing the IN–OUT ranges.
    private var rangeBar: some View {
        GeometryReader { geo in
            let d = max(player.duration, 0.001)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                ForEach(Array(player.marks.spans(duration: player.duration).enumerated()), id: \.offset) { _, span in
                    Capsule().fill(Color.yellow.opacity(0.8))
                        .frame(width: max(2, CGFloat((span.upperBound - span.lowerBound) / d) * geo.size.width))
                        .offset(x: CGFloat(span.lowerBound / d) * geo.size.width)
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

            ViewThatFits(in: .horizontal) {
                wideButtons
                mediumButtons
                stackedButtons
            }
            .disabled(player.take == nil)

            infoBlock
        }
        .frame(maxWidth: .infinity)
        .alert(deletingTake.map { "Delete \($0.name)\($0.slate.map { " · " + $0.shortLabel } ?? "")?" } ?? "",
               isPresented: Binding(get: { deletingTake != nil }, set: { if !$0 { deletingTake = nil } }),
               presenting: deletingTake) { take in
            Button("Move to Trash", role: .destructive) { delete(take) }
            Button("Cancel", role: .cancel) {}
        } message: { take in
            Text(deleteMessage(take))
        }
        .alert("Could not delete the clip", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteError ?? "")
        }
        .sheet(isPresented: $editingSlate) {
            SlateEditSheet(slate: player.slate ?? SlateInfo(),
                           takeName: player.take?.name ?? "",
                           onSave: { saveSlate($0) })
        }
    }

    /// Side controls (IN / OUT, speed, loop, audio, timeline, slate): smaller than the transport buttons.
    private func side<V: View>(_ view: V) -> some View {
        view.buttonStyle(BigButtonStyle(compact: true)).font(.body)
    }

    /// Controls at the left and right window edges (audio, slate, speed, loop): smallest.
    private func edge<V: View>(_ view: V) -> some View {
        view.buttonStyle(BigButtonStyle(small: true)).font(.callout)
    }

    /// Middle group centered, left group at the left edge, right group at the right edge.
    private func threeLine<L: View, C: View, R: View>(_ left: L, _ center: C, _ right: R) -> some View {
        HStack(spacing: 12) {
            left.fixedSize().frame(maxWidth: .infinity, alignment: .leading)
            center.fixedSize()
            right.fixedSize().frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    /// Audio · big transport buttons · speed.
    private func transportLine(playWidth: CGFloat = 160) -> some View {
        threeLine(edge(audioButtons), transportButtons(playWidth: playWidth), edge(speedControl))
    }

    /// Set IN / OUT and add to timeline in one centered group.
    private var marksAndAdd: some View {
        HStack(spacing: 24) { markButtons; addRow }
    }

    /// Wide window: two rows, so the screens above get as much height as possible.
    /// Audio and slate at the left, IN / OUT and timeline in the middle, speed and loop at the right.
    private var wideButtons: some View {
        VStack(spacing: 8) {
            transportLine()
            threeLine(edge(editSlateButton), side(marksAndAdd), edge(loopControl))
            side(goodTakeToggle).fixedSize()
        }
        .frame(minWidth: 1250)   // below this the middle row would crowd its neighbours – medium layout instead
        .buttonStyle(BigButtonStyle())
        .font(.title3)
    }

    /// Medium window (e.g. a laptop): the timeline buttons get their own centered row.
    private var mediumButtons: some View {
        VStack(spacing: 8) {
            transportLine(playWidth: 130)
            threeLine(edge(editSlateButton), side(markButtons), edge(loopControl))
            side(addRow).fixedSize()
            side(goodTakeToggle).fixedSize()
        }
        .buttonStyle(BigButtonStyle())
        .font(.title3)
    }

    /// Narrow window: transport alone, the other groups in rows under it (same sides as in the wider layouts).
    private var stackedButtons: some View {
        VStack(spacing: 8) {
            transportButtons(playWidth: 110).fixedSize()
            threeLine(edge(audioButtons), EmptyView(), edge(speedControl))
            threeLine(edge(editSlateButton), side(markButtons), edge(loopControl))
            side(addRow).fixedSize()
            side(goodTakeToggle).fixedSize()
        }
        .buttonStyle(BigButtonStyle())
        .font(.title3)
    }

    /// Good (circled) take – centered at the bottom of the controls.
    private var goodTakeToggle: some View {
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
        .toggleStyle(SegmentToggleStyle(width: 130, minHeight: 32))
    }

    private var editSlateButton: some View {
        Button("Edit slate…") { editingSlate = true }
    }

    /// Files that go to the Trash, and the sequences that use the clip.
    private func deleteMessage(_ take: Take) -> String {
        let names = TakeLibrary.files(of: take).map(\.lastPathComponent).joined(separator: ", ")
        var text = "These files go to the Trash (they can be put back from there): \(names)."
        let used = timeline.sequences.filter { $0.segments.contains { $0.take == take.number } }.map(\.name)
        if !used.isEmpty {
            text += " The clip is used in the edit (\(used.joined(separator: ", "))) – those pieces will be missing."
        }
        return text
    }

    /// Moves the clip to the Trash, rewrites CLIPLOG.CSV and selects the clip next to it.
    private func delete(_ take: Take) {
        let order = visibleTakes
        let index = order.firstIndex { $0.id == take.id }
        let next = index.flatMap { i in order.indices.contains(i + 1) ? order[i + 1] : (i > 0 ? order[i - 1] : nil) }
        if player.take?.id == take.id { player.load(nil) }
        do {
            try library.moveToTrash(take)
        } catch {
            deleteError = error.localizedDescription
            library.refresh()
            return
        }
        selection = next?.id
        if let folder = take.folder {
            let names = settings.cameraNames
            DispatchQueue.global(qos: .utility).async { ClipLog.rebuild(folder: folder, names: names) }
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
    private func transportButtons(playWidth: CGFloat = 160) -> some View {
        HStack(spacing: 14) {
            Button { selectAdjacentClip(-1) } label: {
                Label("Prev", systemImage: "backward.end.alt.fill")
            }
            .keyboardShortcut(shortcut(.upArrow))
            .disabled(adjacentClip(-1) == nil)
            .help("Previous clip (↑ or ⌘←)")

            Button { player.step(-1) } label: { Image(systemName: "backward.frame.fill") }
                .keyboardShortcut(shortcut(.leftArrow))
                .help("One frame back (←)")
            Button { player.togglePlay() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: playWidth)
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
            .keyboardShortcut(shortcut(.downArrow))
            .disabled(adjacentClip(1) == nil)
            .help("Next clip (↓ or ⌘→)")
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
            .toggleStyle(SegmentToggleStyle(width: 60, minHeight: 24))
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
        .toggleStyle(SegmentToggleStyle(minHeight: 24))
    }

    private var markButtons: some View {
        HStack(spacing: 10) {
            Button("Set IN") { player.setIn() }
                .keyboardShortcut(shortcut("i"))
                .help("IN at the current frame (I) – after an OUT it starts another range")
            Button("Set OUT") { player.setOut() }
                .keyboardShortcut(shortcut("o"))
                .help("OUT at the current frame (O) – closes the range")
            Button("Clear") { player.clearMarks() }
                .disabled(player.marks.isEmpty)
                .help("Remove all IN / OUT ranges of this clip")
        }
    }

    // MARK: - Add to the edit (always one camera)

    /// "Add to timeline: + Camera A  + Camera B" – the IN → OUT piece of one camera.
    private var addRow: some View {
        HStack(spacing: 10) {
            Text("Add to timeline").foregroundStyle(.secondary)
            addButton(.a, key: "a")
            addButton(.b, key: "b")
            Text("\(timeline.segments.count) on timeline").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func addButton(_ role: CameraRole, key: KeyEquivalent) -> some View {
        let name = player.take?.cameraName(role, current: settings.cameraNames) ?? settings.cameraNames.name(role)
        return Button { addToTimeline(role) } label: {
            Label("Camera \(name)", systemImage: "plus")
        }
        .keyboardShortcut(shortcut(key, [.shift]))
        .disabled(file(of: role) == nil)
        .help("Add IN → OUT of camera \(name) to the edit (⇧\(role.rawValue)); without IN / OUT the whole clip")
    }

    private func file(of role: CameraRole) -> URL? {
        role == .a ? player.take?.camA : player.take?.camB
    }

    /// Every IN → OUT range becomes one piece (without ranges: the whole clip).
    private func addToTimeline(_ role: CameraRole) {
        guard let take = player.take, file(of: role) != nil, player.duration > 0 else { return }
        let spans = player.marks.isEmpty ? [0...player.duration] : player.marks.spans(duration: player.duration)
        let label = [take.name, player.slate?.shortLabel].compactMap { $0 }.joined(separator: " · ")
        var added: [TimelineSegment] = []
        for span in spans where span.upperBound - span.lowerBound >= EditTimeline.minimumLength {
            let segment = TimelineSegment(take: take.number, camera: role,
                                          fileA: take.camA?.lastPathComponent, fileB: take.camB?.lastPathComponent,
                                          inPoint: span.lowerBound, outPoint: span.upperBound, clipDuration: player.duration,
                                          label: label)
            timeline.append(segment)
            added.append(segment)
        }
        guard let segment = added.first else { return }
        let total = added.reduce(0) { $0 + $1.duration }
        addedMessageToken += 1
        let token = addedMessageToken
        addedMessage = "Added to timeline: \(take.name) · Camera \(segment.cameraName) · "
            + (added.count > 1 ? "\(added.count) pieces, " : "") + player.timecode(total)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if addedMessageToken == token { addedMessage = nil }
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
            .toggleStyle(SegmentToggleStyle(width: 76, minHeight: 24))
        }
    }

    /// Length of all IN → OUT ranges (without OUT to the end of the clip).
    private var markedDuration: Double? {
        let marks = player.marks
        guard !marks.isEmpty else { return nil }
        return marks.totalDuration(duration: player.duration)
    }

    /// IN/OUT times, slate summary and the A/B offset.
    private var infoBlock: some View {
        VStack(spacing: 4) {
            HStack(spacing: 10) {
                // IN / OUT of the last range; DUR of all ranges together.
                let count = player.marks.ranges.count
                Text("\(count > 1 ? "\(count) ranges · last " : "")IN \(player.marks.inPoint.map { player.timecode($0) } ?? "—")  ·  OUT \(player.marks.outPoint.map { player.timecode($0) } ?? "—")  ·  DUR \(markedDuration.map { player.timecode($0) } ?? "—")")
                    .font(.system(.title3, design: .monospaced))
                if let msg = player.marksMessage {
                    Text(msg).font(.callout).foregroundStyle(.red)
                }
            }
            if let addedMessage {
                Label(addedMessage, systemImage: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
            }
            if player.slate == nil && player.take != nil {
                Text("This clip has no slate data.")
            }
            // Shown only while playing, when A and B drift apart by more than one frame. While scrubbing or
            // seeking the two players catch up at different moments, so the offset there means nothing.
            // The line always takes its place (clip with both cameras): showing it must not move the screens.
            if player.take?.camA != nil && player.take?.camB != nil {
                let offset = player.abOffsetMs ?? 0
                let drifting = abs(offset) > 1000 * player.frameDuration.seconds && player.isPlaying && !isScrubbing
                Label(String(format: "A/B out of sync: B−A %+.1f ms", offset), systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(Color.red)
                    .opacity(drifting ? 1 : 0)
                    .accessibilityHidden(!drifting)
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
    }
}
