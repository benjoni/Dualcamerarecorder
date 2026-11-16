//
//  UpdateView.swift
//  DualCamRecorder
//
//  Update window: a newer build on the website (what is new, Download / Later / Skip this version), or the
//  result of Check for Updates….
//

import SwiftUI

struct UpdateView: View {
    @ObservedObject var updates = UpdateChecker.shared
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 6) {
                    content
                }
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    @ViewBuilder
    private var content: some View {
        switch updates.state {
        case .available(let info):
            Text("DualCamRecorder \(info.version) (\(info.build)) is available").font(.title2.weight(.bold))
            Text("You have \(updates.currentVersion) (\(updates.currentBuild)).").foregroundStyle(.secondary)
            if let notes = info.notes, !notes.isEmpty {
                Text("What's new").font(.headline).padding(.top, 6)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(notes, id: \.self) { note in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•")
                            Text(note).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            Text("Download the zip, quit DualCamRecorder and replace the app with the new one (e.g. in Applications). Your license and projects stay.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            HStack {
                Button("Skip This Version") {
                    updates.skip(info)
                    dismissWindow(id: "update")
                }
                Spacer()
                Button("Later") { dismissWindow(id: "update") }
                    .keyboardShortcut(.cancelAction)
                Button("Download") {
                    updates.download(info)
                    dismissWindow(id: "update")
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 10)
        case .checking:
            Text("Checking for updates…").font(.title2.weight(.bold))
            ProgressView().controlSize(.small)
        case .upToDate:
            Text("DualCamRecorder is up to date").font(.title2.weight(.bold))
            Text("You have the newest version, \(updates.currentVersion) (\(updates.currentBuild)).").foregroundStyle(.secondary)
            okButton
        case .failed(let message):
            Text("Could not check for updates").font(.title2.weight(.bold))
            Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            okButton
        case .idle:
            Text("DualCamRecorder \(updates.currentVersion) (\(updates.currentBuild))").font(.title2.weight(.bold))
            okButton
        }
    }

    private var okButton: some View {
        HStack {
            Spacer()
            Button("OK") { dismissWindow(id: "update") }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.top, 10)
    }
}

/// DualCamRecorder menu → Check for Updates….
struct UpdateMenuButton: View {
    var body: some View {
        Button("Check for Updates…") {
            Task { await UpdateChecker.shared.check(manual: true) }
        }
    }
}

/// App settings: automatic check on / off and Check Now.
struct UpdateSettingsSection: View {
    @ObservedObject var updates = UpdateChecker.shared

    var body: some View {
        Section("Updates") {
            Toggle("Check for new versions automatically (once a day)", isOn: $updates.automatic)
            HStack {
                Text("This version: \(updates.currentVersion) (\(updates.currentBuild))").foregroundStyle(.secondary)
                Spacer()
                Button("Check Now") { Task { await updates.check(manual: true) } }
            }
            Text("Reads dualrecorder.benjoni.com/version.json – nothing about you or this Mac is sent.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Opens the Update window when the checker asks for it (attached to the main window).
/// Also starts the daily check; an update found while recording waits for STOP.
struct UpdateWindowOpener: ViewModifier {
    let recorder: RecordingController
    @ObservedObject var updates = UpdateChecker.shared
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content
            .task {
                updates.isBusy = { [weak recorder] in recorder?.isRecording ?? false }
                updates.start()
            }
            .onChange(of: updates.wantsWindow) { _, wants in
            guard wants else { return }
            updates.wantsWindow = false
            openWindow(id: "update")
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
