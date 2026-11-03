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
    @ObservedObject var backup: BackupManager
    @ObservedObject var monitor: MonitorOutput
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

                Section("Camera list") {
                    ForEach($settings.cameras) { $camera in
                        HStack(spacing: 10) {
                            Text("Camera").foregroundStyle(.secondary)
                            TextField("", text: Binding(
                                get: { camera.name },
                                set: { rename(camera, to: $0) }), prompt: Text("C"))
                                .textFieldStyle(.roundedBorder)
                                .labelsHidden()
                                .frame(width: 60)
                                .help("Starts the file names: C → C007_….MOV")
                            TextField("", text: $camera.model, prompt: Text("Model, e.g. Ronin 4D"))
                                .textFieldStyle(.roundedBorder)
                                .labelsHidden()
                            Button { settings.cameras.removeAll { $0.id == camera.id } } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .disabled(inUse(camera))
                            .help(inUse(camera) ? "Used by an input right now" : "Remove from the list")
                        }
                    }
                    HStack {
                        Button { settings.cameras.append(ProjectCamera(name: nextFreeName())) } label: {
                            Label("Add camera", systemImage: "plus")
                        }
                        Spacer()
                        Text("Picked above each picture on the Record tab.").font(.callout).foregroundStyle(.secondary)
                    }
                }

                Section("Monitor output") {
                    Toggle("Send the picture to a Blackmagic monitor", isOn: $settings.monitorEnabled)
                        .disabled(recorder.outputDevices.isEmpty && !settings.monitorEnabled)
                    if let found = recorder.outputDevices.first {
                        Label(settings.monitorEnabled ? "\(found.displayName) · \(monitor.status)" : "Found: \(found.displayName)",
                              systemImage: monitor.failed && settings.monitorEnabled ? "exclamationmark.triangle.fill" : "display")
                            .foregroundStyle(monitor.failed && settings.monitorEnabled ? .red : .secondary)
                    } else {
                        Label("No UltraStudio Monitor found – connect it, it is used as soon as it appears.",
                              systemImage: "display.trianglebadge.exclamationmark")
                            .foregroundStyle(settings.monitorEnabled ? .red : .secondary)
                    }
                    Text("What goes out (camera \(settings.cameraNames.a), \(settings.cameraNames.b) or both) is chosen with the Monitor button in the toolbar. Record: live picture · Playback: the clip being played · Edit: the cut.")
                        .font(.callout).foregroundStyle(.secondary)
                }

                Section("Camera timecode and REC") {
                    CameraTimecodeSettings(settings: settings, recorder: recorder, folder: settings.recordFolderURL)
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

                Section("Backup copy") {
                    Toggle("Copy clips to a second disk after every take", isOn: $settings.backupEnabled)
                    if settings.backupEnabled {
                        LabeledContent("Backup disk / folder") {
                            HStack {
                                Text(backupPath)
                                    .font(.callout).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                                Button("Choose…") { chooseBackupRoot() }
                            }
                        }
                        LabeledContent("Status") {
                            HStack {
                                backupStatus
                                Button("Back up now") { backup.sync() }
                                    .disabled(settings.backupRootPath.isEmpty)
                            }
                        }
                        Text("Movies, slate / IN-OUT files, CLIPLOG.CSV and PROJECT.JSON are copied into a folder named like the project. Missing or changed files are copied again when the disk is connected (Back up now). The take that is being recorded is copied after STOP.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
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

    private var backupPath: String {
        guard !settings.backupRootPath.isEmpty, let project = model.projects.current,
              let url = BackupManager.destination(root: settings.backupRootPath, projectFolder: project.folder)
        else { return "Not chosen" }
        return url.path
    }

    @ViewBuilder
    private var backupStatus: some View {
        switch backup.state {
        case .off:
            Text("Off").foregroundStyle(.secondary)
        case .idle:
            Label("Up to date" + (backup.lastBackup.map { " · \($0.formatted(date: .omitted, time: .shortened))" } ?? ""),
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .copying(let remaining, let current):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Copying \(current) (\(remaining) left)").lineLimit(1).truncationMode(.middle)
            }
        case .diskMissing:
            Label("Backup disk not connected", systemImage: "externaldrive.badge.xmark").foregroundStyle(.red)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).lineLimit(2)
        }
    }

    private func chooseBackupRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the backup disk or a folder on it – a folder named like the project is created inside."
        if !settings.backupRootPath.isEmpty { panel.directoryURL = URL(fileURLWithPath: settings.backupRootPath) }
        else { panel.directoryURL = URL(fileURLWithPath: "/Volumes") }
        if panel.runModal() == .OK, let url = panel.url { settings.backupRootPath = url.path }
    }

    private func inUse(_ camera: ProjectCamera) -> Bool {
        settings.activeRoles.contains { settings.cameraNames.name($0) == TakeNaming.sanitize(camera.name) }
            || (!settings.twoCameras && settings.cameraNames.a == TakeNaming.sanitize(camera.name))
    }

    /// Renaming a camera an input uses renames the input's camera too (next files C… → D…).
    private func rename(_ camera: ProjectCamera, to name: String) {
        guard let i = settings.cameras.firstIndex(where: { $0.id == camera.id }) else { return }
        let old = TakeNaming.sanitize(camera.name)
        let names = settings.cameraNames
        settings.cameras[i].name = name
        guard !TakeNaming.sanitize(name).isEmpty else { return }
        // (A field emptied while typing keeps no name – the input that lost its camera takes the new one.)
        for role in CameraRole.allCases where names.name(role) == old || (old.isEmpty && settings.camera(role) == nil) {
            recorder.setCameraName(name, for: role)
        }
    }

    /// First letter A, B, C … not used in the list yet.
    private func nextFreeName() -> String {
        let used = Set(settings.cameras.map { TakeNaming.sanitize($0.name) })
        return "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map(String.init).first { !used.contains($0) } ?? ""
    }

    /// Device + camera of the list for one input.
    private func cameraRow(_ role: CameraRole) -> some View {
        LabeledContent(role == .a ? "Input 1" : "Input 2") {
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
                Picker("", selection: Binding(
                    get: { settings.cameraNames.name(role) },
                    set: { recorder.setCameraName($0, for: role) })) {
                    ForEach(settings.cameraChoices(for: role)) { camera in
                        Text(camera.title).tag(TakeNaming.sanitize(camera.name))
                    }
                }
                .labelsHidden()
                .frame(width: 170)
            }
        }
    }
}
