//
//  DualCamRecorderApp.swift
//  DualCamRecorder
//

import SwiftUI

/// Long-lived objects live here so capture keeps running while switching tabs.
final class AppModel: ObservableObject {
    let settings: AppSettings
    let recorder: RecordingController
    let library = TakeLibrary()
    let player = SyncPlaybackController()

    init() {
        settings = AppSettings()
        recorder = RecordingController(settings: settings)
        // Never list the take that is being written right now.
        library.excludedTake = { [weak recorder = self.recorder] in recorder?.activeTake }
        library.cameraNames = { [weak settings = self.settings] in settings?.cameraNames ?? CameraNames() }
    }
}

@main
struct DualCamRecorderApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("DualCamRecorder") {
            ContentView(model: model)
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
    @State private var tab = 0
    /// Hide everything except the camera pictures / players (⌘F).
    @State private var screensOnly = false

    var body: some View {
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
        .toolbar {
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
        .onChange(of: tab) { _, newTab in
            // Preview rendering is not needed while the playback tab is visible.
            model.recorder.channelA.preview.isActive = (newTab == 0)
            model.recorder.channelB.preview.isActive = (newTab == 0)
            if newTab == 1 { model.library.cueLatestOnShow = true }
        }
    }
}
