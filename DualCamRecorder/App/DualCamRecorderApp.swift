//
//  DualCamRecorderApp.swift
//  DualCamRecorder
//

import SwiftUI
import AppKit
import Combine
import CoreMedia

/// Long-lived objects live here so capture keeps running while switching tabs.
final class AppModel: ObservableObject {
    let settings: AppSettings
    let recorder: RecordingController
    let projects: ProjectStore
    let library = TakeLibrary()
    let player = SyncPlaybackController()
    /// Edit for the director (EDIT.JSON in the project folder).
    let timeline = EditTimeline()
    let backup = BackupManager()
    let liveView = LiveViewServer()
    /// Overlay tab: a clip frame with a live camera on top.
    let overlay = OverlayCompositor()
    let monitor = MonitorOutput()
    private var liveViewTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    init() {
        settings = AppSettings()
        recorder = RecordingController(settings: settings)
        projects = ProjectStore(settings: settings)
        // Never list the take that is being written right now.
        library.excludedTake = { [weak recorder = self.recorder] in recorder?.activeTake }
        library.cameraNames = { [weak settings = self.settings] in settings?.cameraNames ?? CameraNames() }
        // Keep the open project's slate (take number, shooting day, …) saved in its PROJECT.JSON.
        settings.$slate
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] slate in self?.projects.saveSlate(slate) }
            .store(in: &cancellables)
        // Live view for phones: camera JPEGs go straight from the preview queue to the server.
        recorder.channelA.preview.onJPEG = { [weak liveView = self.liveView] jpeg in liveView?.updateFrame(camera: "A", jpeg: jpeg) }
        recorder.channelB.preview.onJPEG = { [weak liveView = self.liveView] jpeg in liveView?.updateFrame(camera: "B", jpeg: jpeg) }

        // Blackmagic monitor: live pictures and formats of both inputs, device / source from the project settings.
        recorder.channelA.onPicture = { [weak monitor = self.monitor, weak overlay = self.overlay] picture in
            monitor?.submit(picture, role: .a)
            overlay?.submitLive(picture, role: .a)
        }
        recorder.channelB.onPicture = { [weak monitor = self.monitor, weak overlay = self.overlay] picture in
            monitor?.submit(picture, role: .b)
            overlay?.submitLive(picture, role: .b)
        }
        recorder.channelA.$format.sink { [weak monitor = self.monitor] f in monitor?.setFormat(f, for: .a) }.store(in: &cancellables)
        recorder.channelB.$format.sink { [weak monitor = self.monitor] f in monitor?.setFormat(f, for: .b) }.store(in: &cancellables)
        // Flip / flop of the inputs (project settings, buttons above the pictures).
        settings.$orientationA.removeDuplicates().sink { [weak recorder = self.recorder] o in recorder?.channelA.setOrientation(o) }.store(in: &cancellables)
        settings.$orientationB.removeDuplicates().sink { [weak recorder = self.recorder] o in recorder?.channelB.setOrientation(o) }.store(in: &cancellables)
        // (The output is the first device found with one – the UltraStudio Monitor.)
        settings.$monitorEnabled.combineLatest(settings.$monitorSource, recorder.$outputDevices)
            .sink { [weak monitor = self.monitor] enabled, source, devices in
                let found = devices.first?.identifier
                monitor?.configure(deviceID: enabled ? (found ?? "not-found") : "", source: source, available: found != nil)
            }
            .store(in: &cancellables)

        // Never copy the files of the take that is being recorded.
        backup.isExcluded = { [weak recorder = self.recorder, weak settings = self.settings] name in
            guard let take = recorder?.activeTake, let settings else { return false }
            if let parsed = TakeNaming.parse(name, names: settings.cameraNames) { return parsed.take == take }
            return false
        }
        // Back up after every take (and once more when CLIPLOG.CSV has been rewritten).
        NotificationCenter.default.publisher(for: .takeFinished)
            .sink { [weak self] _ in
                self?.backup.sync()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.backup.sync() }
            }
            .store(in: &cancellables)
        settings.$backupEnabled.combineLatest(settings.$backupRootPath)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _, _ in self?.configureBackup() }
            .store(in: &cancellables)
        // …and its settings (cameras, codec, audio, names, devices).
        settings.objectWillChange
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.projects.saveSettings(self.settings.projectSettings)
            }
            .store(in: &cancellables)
    }

    /// Records into the project folder and restores the project's slate (production/director/DoP filled in).
    func open(_ entry: ProjectEntry) {
        guard !recorder.isRecording else { return }
        if projects.current != nil { closeProject() }
        let opened = projects.markOpened(entry)
        settings.recordFolderPath = opened.folder.path
        // Project settings: cameras, codec, audio … (new / older projects start from the current ones).
        settings.apply(opened.project.settings ?? settings.projectSettings)
        settings.cameraAOn = true
        settings.cameraBOn = true
        projects.saveSettings(settings.projectSettings)
        recorder.restartSources()

        var slate = opened.project.slate ?? {
            // New project: EXT / DAY by default.
            var fresh = SlateInfo()
            fresh.location = .exterior
            fresh.timeOfDay = .day
            return fresh
        }()
        slate.production = opened.project.name
        if !opened.project.director.isEmpty { slate.director = opened.project.director }
        if !opened.project.dop.isEmpty { slate.cameraOperator = opened.project.dop }
        slate.note = ""
        slate.good = false
        slate.recordedAt = nil
        settings.slate = slate

        player.load(nil)
        timeline.load(folder: opened.folder)
        library.cueLatestOnShow = true
        recorder.refreshNextTake()
        configureBackup()
        let folder = opened.folder
        let names = settings.cameraNames
        DispatchQueue.global(qos: .utility).async { ClipLog.rebuild(folder: folder, names: names) }
        NotificationCenter.default.post(name: .takeFinished, object: nil)   // re-scan clip list
    }

    /// Back to the welcome page; the current slate is kept with the project.
    func closeProject() {
        guard !recorder.isRecording else { return }
        player.load(nil)
        timeline.load(folder: nil)
        projects.closeCurrent(saving: settings.slate)
        backup.configure(source: nil, destination: nil)
    }

    // MARK: - Live view for phones

    func setLiveView(_ on: Bool) {
        if on {
            liveView.start()
            liveViewTimer?.invalidate()
            liveViewTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.updateLiveView()
            }
        } else {
            liveView.stop()
            liveViewTimer?.invalidate()
            liveViewTimer = nil
            recorder.channelA.preview.streamEnabled = false
            recorder.channelB.preview.streamEnabled = false
        }
    }

    /// Status for the phone page; JPEGs are only produced while a phone is watching.
    private func updateLiveView() {
        let watching = liveView.hasViewers
        recorder.channelA.preview.streamEnabled = watching && settings.isCameraOn(.a)
        recorder.channelB.preview.streamEnabled = watching && settings.isCameraOn(.b)
        recorder.channelA.preview.streamQuality = liveView.quality
        recorder.channelB.preview.streamQuality = liveView.quality
        guard watching else { return }

        let names = settings.cameraNames
        var files = ""
        if let take = recorder.activeTake {
            files = TakeNaming.fileName(take: take, role: .a, slate: recorder.recordingSlate, names: names)
            if recorder.channelB.isRecording {
                files += "  ·  " + TakeNaming.fileName(take: take, role: .b, slate: recorder.recordingSlate, names: names)
            }
        } else {
            files = "Next: " + TakeNaming.fileName(take: recorder.nextTake, role: .a, slate: settings.slate, names: names)
        }
        let slate = recorder.recordingSlate ?? settings.slate
        let status: [String: Any] = [
            "project": projects.current?.project.name ?? "DualCamRecorder",
            "recording": recorder.isRecording,
            "elapsed": DisplayFormat.duration(recorder.elapsed),
            "files": files,
            "slate": slate.shortLabel + (slate.good ? "  ★" : "") + (slate.mos ? "  MOS" : ""),
            "nameA": names.a,
            "nameB": names.b,
            "showA": settings.isCameraOn(.a),
            "twoCameras": settings.isCameraOn(.b),
        ]
        if let json = try? JSONSerialization.data(withJSONObject: status) {
            liveView.updateStatus(json)
        }
    }

    /// Backup of the open project to <backup root>/<project folder name>, if enabled.
    func configureBackup() {
        guard let project = projects.current, settings.backupEnabled,
              let destination = BackupManager.destination(root: settings.backupRootPath, projectFolder: project.folder)
        else {
            backup.configure(source: nil, destination: nil)
            return
        }
        backup.configure(source: project.folder, destination: destination)
    }

    /// Keeps the open project's details in step after editing it on the welcome page.
    func applyEdited(_ entry: ProjectEntry) {
        guard projects.current?.id == entry.id || projects.current?.folder == entry.folder else { return }
        settings.recordFolderPath = entry.folder.path
        settings.slate.production = entry.project.name
        if !entry.project.director.isEmpty { settings.slate.director = entry.project.director }
        if !entry.project.dop.isEmpty { settings.slate.cameraOperator = entry.project.dop }
        recorder.refreshNextTake()
    }
}

@main
struct DualCamRecorderApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("DualCamRecorder") {
            ContentView(model: model, settings: model.settings, projects: model.projects)
                .frame(minWidth: 1100, minHeight: 700)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1500, height: 950)
        .commands {
            CommandGroup(replacing: .help) { HelpMenuButton() }
        }

        Window("DualCamRecorder Help", id: "help") {
            HelpView()
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 720, height: 760)

        Settings {
            SettingsView(settings: model.settings, controller: model.recorder, model: model)
                .preferredColorScheme(.dark)
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var projects: ProjectStore
    /// 0 Record · 1 Playback · 2 Edit · 3 Overlay
    @State private var tab = 0
    @StateObject private var editPlayer = EditPlayer()
    /// Hide everything except the camera pictures / players (⌘F).
    @State private var screensOnly = false
    @State private var showProjectSettings = false
    @State private var exportingPDF = false
    @Environment(\.openWindow) private var openWindow
    @State private var tabKeyMonitor: Any?

    /// Project name in the middle of the toolbar – no glass capsule around it on macOS 26.
    private var projectTitle: some View {
        Label(projects.current?.project.name ?? "", systemImage: "film")
            .labelStyle(.titleAndIcon)
            .font(.title.weight(.bold))
    }

    var body: some View {
        Group {
            if let project = projects.current {
                workspace
                    .navigationTitle(project.project.name)
                    .modifier(HiddenToolbarTitle())
            } else {
                WelcomeView(model: model, projects: projects, settings: settings)
                    .navigationTitle("DualCamRecorder")
            }
        }
        .onAppear { applyActivity() }
        .onChange(of: settings.showWaveform) { _, _ in applyActivity() }
        .onChange(of: projects.current?.id) { _, _ in
            tab = 0
            screensOnly = false
            applyActivity()
        }
        .onAppear { installTabKeys() }
        #if DEBUG
        .task { await runSnapshotsIfRequested() }
        .task { await runDiskTestIfRequested() }
        #endif
        .onDisappear {
            if let tabKeyMonitor { NSEvent.removeMonitor(tabKeyMonitor) }
            tabKeyMonitor = nil
        }
        .onChange(of: tab) { _, newTab in
            applyActivity()
            if newTab == 1 { model.library.cueLatestOnShow = true }
            if newTab != 1 { model.player.pause() }
        }
    }

    /// Record / Playback of the open project.
    private var workspace: some View {
        Group {
            if screensOnly {
                Group {
                    if tab == 0 {
                        RecordView(controller: model.recorder, settings: model.settings, backup: model.backup, screensOnly: true)
                    } else if tab == 1 {
                        PlaybackView(library: model.library, player: model.player, settings: model.settings,
                                     timeline: model.timeline, screensOnly: true)
                    } else if tab == 2 {
                        EditView(timeline: model.timeline, edit: editPlayer, library: model.library, settings: model.settings, screensOnly: true)
                    } else {
                        OverlayView(compositor: model.overlay, library: model.library, settings: model.settings, screensOnly: true)
                    }
                }
                .background {
                    // Tabs are hidden in this mode – switch with ⌘1 / ⌘2.
                    ZStack {
                        ShortcutButton(key: "1", modifiers: [.command]) { tab = 0 }
                        ShortcutButton(key: "2", modifiers: [.command]) { tab = 1 }
                        ShortcutButton(key: "3", modifiers: [.command]) { tab = 2 }
                        ShortcutButton(key: "4", modifiers: [.command]) { tab = 3 }
                    }
                }
            } else {
                // Record / Playback switch under the toolbar (TabView puts it into the title bar on macOS 26).
                VStack(spacing: 0) {
                    SegmentGroup {
                        Toggle(isOn: Binding(get: { tab == 0 }, set: { if $0 { tab = 0 } })) {
                            Label("Record", systemImage: "record.circle")
                        }
                        .help("Record (R)")
                        Toggle(isOn: Binding(get: { tab == 1 }, set: { if $0 { tab = 1 } })) {
                            Label("Playback", systemImage: "play.fill")
                        }
                        .help("Playback (P)")
                        Toggle(isOn: Binding(get: { tab == 2 }, set: { if $0 { tab = 2 } })) {
                            Label("Edit", systemImage: "scissors")
                        }
                        .help("Edit for the director (E)")
                        Toggle(isOn: Binding(get: { tab == 3 }, set: { if $0 { tab = 3 } })) {
                            Label("Overlay", systemImage: "square.on.square")
                        }
                        .help("A clip frame with the live camera on top – to line up a new take (O)")
                    }
                    .toggleStyle(SegmentToggleStyle(width: 180, minHeight: 38))
                    .font(.title3.weight(.semibold))
                    .padding(.top, 8)
                    if tab == 0 {
                        RecordView(controller: model.recorder, settings: model.settings, backup: model.backup)
                    } else if tab == 1 {
                        PlaybackView(library: model.library, player: model.player, settings: model.settings,
                                     timeline: model.timeline)
                    } else if tab == 2 {
                        EditView(timeline: model.timeline, edit: editPlayer, library: model.library, settings: model.settings)
                    } else {
                        OverlayView(compositor: model.overlay, library: model.library, settings: model.settings)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)   // same corners on Record and Playback
                .overlay(alignment: .bottomTrailing) {
                    Text("DualCamRecorder")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(12)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .bottomLeading) {
                    Text("Made by BENJONI")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(12)
                        .allowsHitTesting(false)
                }
            }
        }
        .overlay { DiskAlertOverlay(recorder: model.recorder) }
        .sheet(isPresented: $exportingPDF) {
            ExportPDFSheet(library: model.library, settings: settings)
        }
        .sheet(isPresented: $showProjectSettings) {
            ProjectSettingsView(model: model, settings: settings, recorder: model.recorder, backup: model.backup, monitor: model.monitor)
        }
        .toolbar {
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .principal) { projectTitle }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .principal) { projectTitle }
            }
            ToolbarItem(placement: .navigation) {
                Button {
                    model.closeProject()
                } label: {
                    Label("Projects", systemImage: "square.grid.2x2")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(model.recorder.isRecording)
                .help(model.recorder.isRecording ? "Stop recording first" : "Back to the project list")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    exportingPDF = true
                } label: {
                    Label("Export PDF…", systemImage: "doc.richtext")
                        .labelStyle(.titleAndIcon)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .help("Clip report by shooting day, with pictures (⇧⌘P)")
                .disabled(model.recorder.isRecording)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showProjectSettings = true
                } label: {
                    Label("Project settings", systemImage: "gearshape")
                        .labelStyle(.titleAndIcon)
                }
                .keyboardShortcut(",", modifiers: [.command, .option])
                .help("Cameras, codec, audio of this project (⌥⌘,)")
            }
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $settings.showWaveform) {
                    Label("Waveform", systemImage: "waveform.path.ecg")
                        .labelStyle(.titleAndIcon)
                }
                .toggleStyle(.button)
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .help("Luma waveform over each picture (⇧⌘W)")
            }
            if settings.monitorEnabled {
                ToolbarItem(placement: .primaryAction) { MonitorMenu(settings: settings, monitor: model.monitor) }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    openWindow(id: "help")
                } label: {
                    Label("Help", systemImage: "questionmark.circle")
                        .labelStyle(.titleAndIcon)
                }
                .help("Keyboard shortcuts, symbols and file names (⌘?)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    screensOnly.toggle()
                } label: {
                    Label(screensOnly ? "Show controls" : "Screens only",
                          systemImage: screensOnly ? "slider.horizontal.3" : "rectangle.split.2x1")
                        .labelStyle(.titleAndIcon)
                }
                .keyboardShortcut("f", modifiers: [.command])
                .help(screensOnly ? "Show all controls (⌘F)" : "Hide everything except the pictures (⌘F)")
            }
        }
    }


    /// R → Record, P → Playback, E → Edit, O → Overlay (plain keys, ignored while typing in a text field).
    private func installTabKeys() {
        guard tabKeyMonitor == nil else { return }
        tabKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard projects.current != nil,
                  event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                  !(NSApp.keyWindow?.firstResponder is NSText),
                  NSApp.keyWindow?.attachedSheet == nil else { return event }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "r": tab = 0; return nil
            case "p": tab = 1; return nil
            case "e": tab = 2; return nil
            case "o": tab = 3; return nil
            default: return event
            }
        }
    }

    /// Previews / waveforms only where they are visible.
    private func applyActivity() {
        let inProject = projects.current != nil
        let recordVisible = inProject && tab == 0
        let playbackVisible = inProject && tab == 1
        model.recorder.channelA.preview.isActive = recordVisible
        model.recorder.channelB.preview.isActive = recordVisible
        model.recorder.channelA.preview.waveformEnabled = settings.showWaveform && recordVisible
        model.recorder.channelB.preview.waveformEnabled = settings.showWaveform && recordVisible
        model.player.waveformEnabled = settings.showWaveform && playbackVisible
        model.overlay.isActive = inProject && tab == 3
        // Monitor output: the clip being played on Playback, the cut on Edit, the cameras everywhere else.
        if playbackVisible {
            model.monitor.setPlayback { [weak player = model.player] in
                player?.monitorFrames() ?? MonitorPlaybackFrames(frameDuration: CMTime(value: 1, timescale: 25))
            }
        } else if inProject && tab == 3 {
            model.monitor.setPlayback { [weak overlay = model.overlay] in
                overlay?.monitorFrames ?? MonitorPlaybackFrames(frameDuration: CMTime(value: 1, timescale: 25), program: true)
            }
        } else if inProject && tab == 2 {
            model.monitor.setPlayback { [weak edit = editPlayer] in
                edit?.monitorFrames() ?? MonitorPlaybackFrames(frameDuration: CMTime(value: 1, timescale: 25), program: true)
            }
        } else {
            model.monitor.setPlayback(nil)
        }
    }
}


#if DEBUG
extension ContentView {
    /// Debug only: `-snapshotDir <folder> -snapshotProject <name>` opens the project, saves pictures of the
    /// window for Record / Playback / Edit (drawn by the app itself, works without screen capture) and quits.
    @MainActor
    func runSnapshotsIfRequested() async {
        let args = UserDefaults.standard
        guard let dir = args.string(forKey: "snapshotDir"), let name = args.string(forKey: "snapshotProject") else { return }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        guard let entry = projects.projects.first(where: { $0.project.name == name }) else { exit(2) }
        model.open(entry)
        // -snapshotWindowSize 1372x869: pictures of a smaller window.
        if let size = args.string(forKey: "snapshotWindowSize")?.split(separator: "x").compactMap({ Double($0) }), size.count == 2,
           let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) {
            window.setContentSize(NSSize(width: size[0], height: size[1]))
        }
        for (index, label) in ["record", "playback", "edit"].enumerated() {
            tab = index
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            saveWindowPicture(to: URL(fileURLWithPath: dir).appendingPathComponent("\(label).png"))
        }
        // Overlay tab: the window and the composed picture in each mode.
        tab = 3
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        saveWindowPicture(to: URL(fileURLWithPath: dir).appendingPathComponent("overlay.png"))
        for mode in OverlayMode.allCases {
            model.overlay.mode = mode
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            try? model.overlay.debugCompositePNG()?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("overlay_\(mode.rawValue).png"))
        }
        // …and with the demo pictures.
        model.overlay.setDemoLive(OverlayCompositor.assetPicture(named: "DemoClose"))
        model.overlay.setStill(OverlayCompositor.assetPicture(named: "DemoWide"), frameDuration: CMTime(value: 1, timescale: 25))
        for mode in OverlayMode.allCases {
            model.overlay.mode = mode
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            try? model.overlay.debugCompositePNG()?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("overlay_demo_\(mode.rawValue).png"))
        }
        model.overlay.setDemoLive(nil)
        model.overlay.mode = .mix
        tab = 0
        // Live view for phones: server on, its settings section drawn off screen.
        model.setLiveView(true)
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        let live = NSHostingView(rootView: Form { LiveViewSettingsSection(model: model, server: model.liveView) }
            .formStyle(.grouped).frame(width: 720, height: 520).preferredColorScheme(.dark))
        live.frame = NSRect(x: 0, y: 0, width: 720, height: 520)
        live.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 500_000_000)
        if let rep = live.bitmapImageRepForCachingDisplay(in: live.bounds) {
            live.cacheDisplay(in: live.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("live_view.png"))
        }
        // Project settings sheet, drawn off screen.
        let sheet = NSHostingView(rootView: ProjectSettingsView(model: model, settings: settings, recorder: model.recorder, backup: model.backup, monitor: model.monitor)
            .frame(width: 720, height: 900).preferredColorScheme(.dark))
        sheet.frame = NSRect(x: 0, y: 0, width: 720, height: 900)
        sheet.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        if let rep = sheet.bitmapImageRepForCachingDisplay(in: sheet.bounds) {
            sheet.cacheDisplay(in: sheet.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("project_settings.png"))
        }
        // Help window, whole content (no scroll view).
        let help = NSHostingView(rootView: HelpView.content.frame(width: 900).fixedSize(horizontal: false, vertical: true)
            .background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.dark))
        help.frame = NSRect(origin: .zero, size: help.fittingSize)
        help.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 500_000_000)
        if let rep = help.bitmapImageRepForCachingDisplay(in: help.bounds) {
            help.cacheDisplay(in: help.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("help.png"))
        }
        // Clip reports of the project (landscape + portrait, camera setup lines when any clip has them).
        for portrait in [false, true] {
            let takes = model.library.takes
            let options = ReportOptions(portrait: portrait, cameraNames: settings.cameraNames,
                                        cameraSetup: takes.contains { $0.slate.map { !$0.setupA.isEmpty || !$0.setupB.isEmpty } ?? false })
            let clips = await PDFReport.prepare(takes: takes, options: options)
            try? PDFReport.write(clips: clips, production: settings.slate.production, options: options,
                                 to: URL(fileURLWithPath: dir).appendingPathComponent(portrait ? "report_portrait.pdf" : "report.pdf"))
        }
        exit(0)
    }

    /// Debug only: `-diskTestProject <name> -diskTestDir <folder>` opens the project, starts recording, writes
    /// `recording` into the folder and waits for the project's disk to be detached (from outside); then saves
    /// disk_alert.png and result.txt and quits.
    @MainActor
    func runDiskTestIfRequested() async {
        let args = UserDefaults.standard
        guard let dir = args.string(forKey: "diskTestDir"), let name = args.string(forKey: "diskTestProject") else { return }
        let out = URL(fileURLWithPath: dir)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        guard let entry = projects.projects.first(where: { $0.project.name == name }) else { exit(2) }
        model.open(entry)
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        model.recorder.startRecording()
        try? "\(model.recorder.isRecording) \(model.recorder.errorMessage ?? "")".write(to: out.appendingPathComponent("recording"), atomically: true, encoding: .utf8)
        if args.integer(forKey: "debugWriteDelay") > 0 {   // slow disk: no detach, pictures during and after the take
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            saveWindowPicture(to: out.appendingPathComponent("slow_write.png"))
            let during = model.recorder.writeWarning ?? "none"
            model.recorder.stopRecording()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            saveWindowPicture(to: out.appendingPathComponent("slow_after.png"))
            let stats = [model.recorder.channelA.stats, model.recorder.channelB.stats]
                .map { "written \($0.framesWritten) dropped(write) \($0.writerDropped)" }
            try? ([ "during: \(during)", "after: \(model.recorder.writeWarning ?? "none")",
                    "lastTake: \(model.recorder.lastTakeMessage ?? "")"] + stats)
                .joined(separator: "\n").write(to: out.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
            exit(0)
        }
        for _ in 0..<600 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if let alert = model.recorder.diskAlert, !alert.details.isEmpty, !model.recorder.isRecording { break }
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        saveWindowPicture(to: out.appendingPathComponent("disk_alert.png"))
        let alert = model.recorder.diskAlert
        let result = ["alert: \(alert.map { "\($0.volumeName) take \($0.take) after \($0.stoppedAfter)" } ?? "none")",
                      "state: \(model.recorder.state)", "lastTake: \(model.recorder.lastTakeMessage ?? "")",
                      "error: \(model.recorder.errorMessage ?? "")", "slate take now: \(settings.slate.take)"]
            + (alert?.details ?? [])
        try? result.joined(separator: "\n").write(to: out.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
        exit(0)
    }

    @MainActor
    private func saveWindowPicture(to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let view = window.contentView?.superview ?? window.contentView else { return }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif

/// What goes to the Blackmagic monitor (Project settings → Monitor output turns it on).
/// Its own view so the output state ("Sending 1080p25", "not connected" …) stays current.
private struct MonitorMenu: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var monitor: MonitorOutput

    var body: some View {
        let names = settings.cameraNames
        let title: String
        switch settings.monitorSource {
        case .a: title = "Monitor \(names.a)"
        case .b: title = "Monitor \(names.b)"
        case .both: title = "Monitor \(names.a)|\(names.b)"
        }
        return Menu {
            Picker("Show on the monitor", selection: $settings.monitorSource) {
                Text("Camera \(names.a)").tag(MonitorSource.a)
                if settings.twoCameras {
                    Text("Camera \(names.b)").tag(MonitorSource.b)
                    Text("Both side by side (\(names.a) | \(names.b))").tag(MonitorSource.both)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Text(monitor.status)
        } label: {
            Label(title, systemImage: monitor.failed ? "exclamationmark.triangle" : "display")
                .labelStyle(.titleAndIcon)
        }
        .help("What goes to the Blackmagic monitor – \(monitor.status)")
    }
}

/// The project name is shown centered in the toolbar; hide the default title on the left (macOS 15+).
private struct HiddenToolbarTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbar(removing: .title)
        } else {
            content
        }
    }
}

/// Help menu → DualCamRecorder Help (⌘?).
private struct HelpMenuButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("DualCamRecorder Help") { openWindow(id: "help") }
            .keyboardShortcut("?", modifiers: [.command])
    }
}
