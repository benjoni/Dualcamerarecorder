//
//  SettingsView.swift
//  DualCamRecorder
//

import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var controller: RecordingController

    var body: some View {
        Form {
            Section("Folders") {
                LabeledContent("Recording folder (open project)") {
                    Text(settings.recordFolderPath).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                folderRow(title: "New projects are created in", path: settings.projectsRootPath) { settings.projectsRootPath = $0 }
            }

            Section("Project settings") {
                Text("Cameras (1 or 2), devices, camera names, codec, audio and bit depth are set per project – use “Project settings” (⚙, ⌥⌘,) in the project window.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section("DeckLink") {
                Text(controller.sdkStatus).font(.callout)
                if controller.devices.isEmpty {
                    Text("No device found. Use “Simulated input” to test the UI.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(controller.devices, id: \.identifier) { d in
                    Text("\(d.displayName) · \(d.modelName) · id \(d.identifier) · audio max \(d.maxAudioChannels) ch")
                        .font(.caption.monospaced())
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 620)
        .padding()
    }

    private func folderRow(title: String, path: String, set: @escaping (String) -> Void) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title)
                Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.canCreateDirectories = true
                panel.directoryURL = URL(fileURLWithPath: path)
                if panel.runModal() == .OK, let url = panel.url { set(url.path) }
            }
            .disabled(controller.isRecording)
        }
    }
}
