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
                Toggle("Play back from another disk / folder", isOn: $settings.separatePlaybackFolder)
                if settings.separatePlaybackFolder {
                    folderRow(title: "Read (playback)", path: settings.playbackFolderPath) { settings.playbackFolderPath = $0 }
                }
                Text("When recording and playing back at the same time, it is safest to read from a different disk than the one being written to.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Camera names (start of the file name)") {
                HStack {
                    TextField("Camera A", text: Binding(get: { settings.cameraNameA },
                                                        set: { controller.setCameraName($0, for: .a) }))
                    TextField("Camera B", text: Binding(get: { settings.cameraNameB },
                                                        set: { controller.setCameraName($0, for: .b) }))
                }
                .disabled(controller.isRecording)
                Text("Example: \(TakeNaming.fileName(take: controller.nextTake, role: .a, slate: settings.slate, names: settings.cameraNames))  ·  \(TakeNaming.fileName(take: controller.nextTake, role: .b, slate: settings.slate, names: settings.cameraNames))")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                Text("After renaming a camera, older files with the previous name are not listed until the name is changed back.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Recording") {
                Picker("Codec", selection: $settings.proResFlavor) {
                    ForEach(ProResFlavor.allCases) { Text($0.title).tag($0) }
                }
                Picker("Audio (SDI embedded)", selection: $settings.audioChannels) {
                    Text("Off").tag(0)
                    Text("2 channels").tag(2)
                    Text("8 channels").tag(8)
                    Text("16 channels").tag(16)
                }
                Toggle("Force 8-bit capture (otherwise 10-bit when the source sends it)", isOn: $settings.forceEightBit)
                Button("Apply audio / bit depth changes (restart inputs)") { controller.restartSources() }
                    .disabled(controller.isRecording)
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
