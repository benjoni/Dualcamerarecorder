//
//  ProjectSettingsView.swift
//  DualCamRecorder
//
//  Settings of the open project: one or two cameras, devices and names, codec, audio, bit depth.
//  Everything is stored in the project's PROJECT.JSON (see AppModel) and restored when it is opened.
//

import SwiftUI
import AppKit

struct ProjectSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var recorder: RecordingController
    @Environment(\.dismiss) private var dismiss

    /// Audio / bit depth need the inputs restarted – done once when the sheet closes.
    @State private var needsInputRestart = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Project settings").font(.title2.weight(.bold))
                Spacer()
                if let project = model.projects.current {
                    Text(project.project.name).font(.title3).foregroundStyle(.secondary)
                }
            }

            Form {
                Section("Cameras") {
                    Picker("Record with", selection: Binding(
                        get: { settings.cameraCount },
                        set: { recorder.setCameraCount($0) })) {
                        Text("1 camera").tag(1)
                        Text("2 cameras").tag(2)
                    }
                    .pickerStyle(.segmented)

                    cameraRow(.a)
                    if settings.twoCameras {
                        cameraRow(.b)
                    }
                    Text("Files: \(TakeNaming.fileName(take: recorder.nextTake, role: .a, slate: settings.slate, names: settings.cameraNames))"
                         + (settings.twoCameras ? "  ·  \(TakeNaming.fileName(take: recorder.nextTake, role: .b, slate: settings.slate, names: settings.cameraNames))" : ""))
                        .font(.callout.monospaced()).foregroundStyle(.secondary)
                }

                Section("Recording") {
                    Picker("Codec", selection: $settings.proResFlavor) {
                        ForEach(ProResFlavor.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Audio (SDI embedded)", selection: Binding(
                        get: { settings.audioChannels },
                        set: { settings.audioChannels = $0; needsInputRestart = true })) {
                        Text("Off").tag(0)
                        Text("2 channels").tag(2)
                        Text("8 channels").tag(8)
                        Text("16 channels").tag(16)
                    }
                    Toggle("Force 8-bit capture (otherwise 10-bit when the source sends it)", isOn: Binding(
                        get: { settings.forceEightBit },
                        set: { settings.forceEightBit = $0; needsInputRestart = true }))
                }

                if let project = model.projects.current {
                    Section("Folder") {
                        LabeledContent("Recordings") {
                            HStack {
                                Text(project.folder.path)
                                    .font(.callout).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                                Button("Show in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([project.folder])
                                }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .controlSize(.large)
            .disabled(recorder.isRecording)

            if recorder.isRecording {
                Text("Settings cannot be changed while recording.").foregroundStyle(.red)
            }
            HStack {
                Text("Saved with the project automatically.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .padding(24)
        .frame(width: 680)
        .onDisappear {
            if needsInputRestart { recorder.restartSources() }
        }
    }

    /// Device + file-name prefix for one camera.
    private func cameraRow(_ role: CameraRole) -> some View {
        LabeledContent("Camera \(role.rawValue)") {
            HStack(spacing: 10) {
                Picker("", selection: Binding(
                    get: { recorder.assignedID(role) },
                    set: { recorder.assign($0, to: role) })) {
                    ForEach(recorder.deviceOptions) { option in
                        Text(option.title).tag(option.id)
                    }
                }
                .labelsHidden()
                .frame(minWidth: 260)
                Text("Name").foregroundStyle(.secondary)
                TextField(role.rawValue, text: Binding(
                    get: { role == .a ? settings.cameraNameA : settings.cameraNameB },
                    set: { recorder.setCameraName($0, for: role) }))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
            }
        }
    }
}
