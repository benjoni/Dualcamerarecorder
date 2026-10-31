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

    var body: some View {
        TabView(selection: $tab) {
            RecordView(controller: model.recorder, settings: model.settings)
                .tabItem { Label("Nahrávanie", systemImage: "record.circle") }
                .tag(0)
            PlaybackView(library: model.library, player: model.player, settings: model.settings)
                .tabItem { Label("Prehrávanie", systemImage: "play.rectangle") }
                .tag(1)
        }
        .padding(.top, 4)
        .onChange(of: tab) { _, newTab in
            // Preview rendering is not needed while the playback tab is visible.
            model.recorder.channelA.preview.isActive = (newTab == 0)
            model.recorder.channelB.preview.isActive = (newTab == 0)
        }
    }
}
