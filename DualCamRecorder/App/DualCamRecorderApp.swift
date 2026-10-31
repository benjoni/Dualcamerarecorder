//
//  DualCamRecorderApp.swift
//  DualCamRecorder
//

import SwiftUI
import Combine

/// Long-lived objects live here so capture keeps running while switching tabs.
final class AppModel: ObservableObject {
    let settings: AppSettings
    let recorder: RecordingController
    let projects: ProjectStore
    let library = TakeLibrary()
    let player = SyncPlaybackController()
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
        projects.saveSettings(settings.projectSettings)
        recorder.restartSources()

        var slate = opened.project.slate ?? SlateInfo()
        slate.production = opened.project.name
        if !opened.project.director.isEmpty { slate.director = opened.project.director }
        if !opened.project.dop.isEmpty { slate.cameraOperator = opened.project.dop }
        slate.note = ""
        slate.good = false
        slate.recordedAt = nil
        settings.slate = slate

        player.load(nil)
        library.cueLatestOnShow = true
        recorder.refreshNextTake()
        NotificationCenter.default.post(name: .takeFinished, object: nil)   // re-scan clip list
    }

    /// Back to the welcome page; the current slate is kept with the project.
    func closeProject() {
        guard !recorder.isRecording else { return }
        player.load(nil)
        projects.closeCurrent(saving: settings.slate)
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
        }
        .defaultSize(width: 1500, height: 950)

        Settings {
            SettingsView(settings: model.settings, controller: model.recorder)
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var projects: ProjectStore
    @State private var tab = 0
    /// Hide everything except the camera pictures / players (⌘F).
    @State private var screensOnly = false
    @State private var showProjectSettings = false

    var body: some View {
        Group {
            if let project = projects.current {
                workspace
                    .navigationTitle(project.project.name)
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
        .onChange(of: tab) { _, newTab in
            applyActivity()
            if newTab == 1 { model.library.cueLatestOnShow = true }
        }
    }

    /// Record / Playback of the open project.
    private var workspace: some View {
        Group {
            if screensOnly {
                Group {
                    if tab == 0 {
                        RecordView(controller: model.recorder, settings: model.settings, screensOnly: true)
                    } else {
                        PlaybackView(library: model.library, player: model.player, settings: model.settings,
                                     screensOnly: true)
                    }
                }
                .background {
                    // Tabs are hidden in this mode – switch with ⌘1 / ⌘2.
                    ZStack {
                        ShortcutButton(key: "1", modifiers: [.command]) { tab = 0 }
                        ShortcutButton(key: "2", modifiers: [.command]) { tab = 1 }
                    }
                }
            } else {
                TabView(selection: $tab) {
                    RecordView(controller: model.recorder, settings: model.settings)
                        .tabItem { Label("Record", systemImage: "record.circle") }
                        .tag(0)
                    PlaybackView(library: model.library, player: model.player, settings: model.settings)
                        .tabItem { Label("Playback", systemImage: "play.rectangle") }
                        .tag(1)
                }
                .padding(.top, 4)
            }
        }
        .sheet(isPresented: $showProjectSettings) {
            ProjectSettingsView(model: model, settings: settings, recorder: model.recorder)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    model.closeProject()
                } label: {
                    Label("Projects", systemImage: "square.grid.2x2")
                }
                .disabled(model.recorder.isRecording)
                .help(model.recorder.isRecording ? "Stop recording first" : "Back to the project list")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showProjectSettings = true
                } label: {
                    Label("Project settings", systemImage: "gearshape")
                }
                .keyboardShortcut(",", modifiers: [.command, .option])
                .help("Cameras, codec, audio of this project (⌥⌘,)")
            }
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $settings.showWaveform) {
                    Label("Waveform", systemImage: "waveform.path.ecg")
                }
                .toggleStyle(.button)
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .help("Luma waveform over each picture (⇧⌘W)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    screensOnly.toggle()
                } label: {
                    Label(screensOnly ? "Show controls" : "Screens only",
                          systemImage: screensOnly ? "slider.horizontal.3" : "rectangle.split.2x1")
                }
                .keyboardShortcut("f", modifiers: [.command])
                .help(screensOnly ? "Show all controls (⌘F)" : "Hide everything except the pictures (⌘F)")
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
    }
}
