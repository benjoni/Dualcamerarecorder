//
//  RecordView.swift
//  DualCamRecorder
//

import SwiftUI
import AppKit

struct RecordView: View {
    @ObservedObject var controller: RecordingController
    @ObservedObject var settings: AppSettings
    @ObservedObject var backup: BackupManager
    /// Only the two camera pictures, nothing else (toggled with ⌘F).
    var screensOnly = false

    var body: some View {
        if screensOnly {
            screensOnlyBody
        } else {
            normalBody
        }
    }

    /// Both pictures filling the window; shortcuts (⌘R, ⌘I, ⌘O) keep working.
    private var screensOnlyBody: some View {
        HStack(spacing: 8) {
            if settings.isCameraOn(.a) {
                CameraScreen(channel: controller.channelA, showWaveform: settings.showWaveform)
            }
            if settings.isCameraOn(.b) {
                CameraScreen(channel: controller.channelB, showWaveform: settings.showWaveform)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .background {
            ZStack {
                ShortcutButton(key: "r", modifiers: [.command]) { controller.toggleRecording() }
                ShortcutButton(key: "i", modifiers: [.command]) { controller.markIn() }
                ShortcutButton(key: "o", modifiers: [.command]) { controller.markOut() }
                ShortcutButton(key: "1", modifiers: [.option]) { controller.toggleCamera(.a) }
                ShortcutButton(key: "2", modifiers: [.option]) { controller.toggleCamera(.b) }
            }
        }
    }

    private var normalBody: some View {
        VStack(spacing: 12) {
            if settings.twoCameras {
                cameraSwitches
            }
            HStack(alignment: .top, spacing: 12) {
                if settings.isCameraOn(.a) {
                    CameraPanel(controller: controller, channel: controller.channelA, showWaveform: settings.showWaveform)
                }
                if settings.isCameraOn(.b) {
                    CameraPanel(controller: controller, channel: controller.channelB, showWaveform: settings.showWaveform)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: settings.cameraAOn)
            .animation(.easeInOut(duration: 0.2), value: settings.cameraBOn)
            Divider()
            transportBar
            Divider()
            SlatePanel(controller: controller, settings: settings)
            if let error = controller.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding()
    }

    /// All controls centered: REC / timer / IN-OUT on the first row, disk info below.
    /// REC/STOP, IN and OUT side by side with the same height; timer, file names and IN/OUT times below.
    private var transportBar: some View {
        let recording: Bool = {
            if case .recording = controller.state { return true }
            return false
        }()
        return VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Button(action: controller.toggleRecording) {
                    HStack(spacing: 10) {
                        Image(systemName: controller.isRecording ? "stop.fill" : "record.circle")
                            .font(.system(size: 28))
                        Text(recordButtonTitle)
                            .font(.title2.weight(.bold))
                    }
                    .frame(width: 180, height: 48)
                }
                .buttonStyle(.borderedProminent)
                .tint(controller.isRecording ? .gray : .red)
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(isStopping)

                Group {
                    Button { controller.markIn() } label: {
                        Text("IN").font(.title2.weight(.bold)).frame(width: 90, height: 48)
                    }
                    .keyboardShortcut("i", modifiers: [.command])
                    .help("Set IN at the current take time (⌘I)")
                    Button { controller.markOut() } label: {
                        Text("OUT").font(.title2.weight(.bold)).frame(width: 90, height: 48)
                    }
                    .keyboardShortcut("o", modifiers: [.command])
                    .help("Set OUT at the current take time (⌘O)")
                }
                .buttonStyle(.bordered)
                .disabled(!recording)

                Button { controller.clearMarks() } label: { Image(systemName: "xmark.circle").font(.title2) }
                    .buttonStyle(.borderless)
                    .help("Clear IN/OUT")
                    .disabled(!recording || controller.marks.isEmpty)
            }

            Text(DisplayFormat.duration(controller.elapsed))
                .font(.system(size: 30, weight: .semibold, design: .monospaced))
                .foregroundStyle(controller.isRecording ? .red : .primary)
            Text(takeLabel).font(.body).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("IN \(DisplayFormat.mark(controller.marks.inPoint))  ·  OUT \(DisplayFormat.mark(controller.marks.outPoint))")
                .font(.system(.title3, design: .monospaced))
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Image(systemName: "internaldrive")
                Text("Free: \(DisplayFormat.bytes(controller.freeBytes)) of \(DisplayFormat.bytes(controller.totalBytes))")
                if let free = controller.freeBytes, let total = controller.totalBytes, total > 0 {
                    ProgressView(value: Double(total - free), total: Double(total))
                        .frame(width: 160)
                        .tint(Double(free) / Double(total) < 0.1 ? .red : .accentColor)
                }
                Text("Recording time left: \(DisplayFormat.remaining(controller.estimatedRemaining))")
                    .foregroundStyle(.secondary)
                Text(settings.recordFolderPath)
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 300)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([settings.recordFolderURL])
                }
                if let status = backup.shortStatus {
                    Label(status, systemImage: backup.isProblem ? "externaldrive.badge.xmark" : "externaldrive.badge.checkmark")
                        .foregroundStyle(backup.isProblem ? Color.red : Color.secondary)
                }
            }
            .font(.callout)
        }
        .frame(maxWidth: .infinity)
    }

    private var isStopping: Bool {
        if case .stopping = controller.state { return true }
        return false
    }

    private var recordButtonTitle: String {
        switch controller.state {
        case .idle: return "REC"
        case .recording: return "STOP"
        case .stopping: return "Saving…"
        }
    }

    /// Two-camera projects: switch camera A or B off for a while – the other fills the screen and records alone.
    private var cameraSwitches: some View {
        HStack(spacing: 12) {
            Text("Cameras").foregroundStyle(.secondary)
            SegmentGroup {
                ForEach(CameraRole.allCases) { role in
                    Toggle(isOn: Binding(get: { settings.isCameraOn(role) },
                                         set: { controller.setCamera(role, on: $0) })) {
                        Label("Camera \(role.rawValue)", systemImage: settings.isCameraOn(role) ? "video.fill" : "video.slash")
                    }
                    .help("Camera \(role.rawValue) on / off (⌥\(role == .a ? 1 : 2))")
                }
            }
            .toggleStyle(SegmentToggleStyle(width: 150))
            .disabled(controller.isRecording)
            .background {
                ZStack {
                    ShortcutButton(key: "1", modifiers: [.option]) { controller.toggleCamera(.a) }
                    ShortcutButton(key: "2", modifiers: [.option]) { controller.toggleCamera(.b) }
                }
            }
            if settings.activeRoles.count == 1 {
                Text("Only camera \(settings.activeRoles[0].rawValue) records")
                    .foregroundStyle(.orange)
            }
        }
        .font(.title3)
        .frame(maxWidth: .infinity)
    }

    private var takeLabel: String {
        var parts: [String] = []
        let names = settings.cameraNames
        let roles = controller.isRecording
            ? CameraRole.allCases.filter { controller.channel($0).isRecording }
            : settings.activeRoles
        if let active = controller.activeTake {
            let files = roles.map { TakeNaming.fileName(take: active, role: $0, slate: controller.recordingSlate, names: names) }
            parts.append("Recording " + files.joined(separator: " + "))
        } else {
            let files = roles.map { TakeNaming.fileName(take: controller.nextTake, role: $0, slate: settings.slate, names: names) }
            parts.append("Next files: " + files.joined(separator: " + "))
        }
        if let offset = controller.lastStartOffsetMs, !controller.isRecording {
            parts.append(String(format: "start offset B−A: %+.1f ms", offset))
        }
        if let msg = controller.lastTakeMessage, !controller.isRecording { parts.append(msg) }
        return parts.joined(separator: " · ")
    }
}

/// Device picker + live preview + status for one camera.
struct CameraPanel: View {
    @ObservedObject var controller: RecordingController
    @ObservedObject var channel: CameraChannel
    var showWaveform = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Camera \(channel.role.rawValue)")
                    .font(.title3.weight(.bold))
                // Input device is chosen in Project settings.
                Spacer(minLength: 12)
                Text("Name").font(.caption).foregroundStyle(.secondary)
                TextField("A", text: Binding(
                    get: { channel.role == .a ? controller.settings.cameraNameA : controller.settings.cameraNameB },
                    set: { controller.setCameraName($0, for: channel.role) }))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .disabled(controller.isRecording)
                    .help("Camera name at the start of the file name, e.g. A → A007_S12_SH3B_T04.MOV")
                Text("Cam clip").font(.caption).foregroundStyle(.secondary)
                TextField("A001C0001", text: cameraClipBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .frame(minWidth: 150, idealWidth: 190, maxWidth: 230)
                    .disabled(controller.isRecording)
                    .help("Clip name in the camera's own recording (e.g. A001C0023). Its last number goes up by 1 after every take; saved with the clip.")
                Stepper("",
                        onIncrement: { cameraClipBinding.wrappedValue = CameraClipID.next(cameraClipBinding.wrappedValue) },
                        onDecrement: { cameraClipBinding.wrappedValue = CameraClipID.previous(cameraClipBinding.wrappedValue) })
                    .labelsHidden()
                    .disabled(controller.isRecording)
            }

            CameraScreen(channel: channel, showWaveform: showWaveform)

            Text(channel.format?.displayString ?? "Format: —")
                .font(.system(.body, design: .monospaced))
            AudioMeter(db: channel.audioLevelDB)
            HStack(spacing: 16) {
                stat("Captured", channel.stats.framesCaptured)
                stat("Written", channel.stats.framesWritten)
                stat("Dropped (input)", channel.stats.inputDropped, alert: channel.stats.inputDropped > 0)
                stat("Dropped (write)", channel.stats.writerDropped, alert: channel.stats.writerDropped > 0)
            }
            .font(.callout)
            if let error = channel.lastError {
                Text(error).font(.callout).foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Camera's internal clip name (frozen value of the running take while recording).
    private var cameraClipBinding: Binding<String> {
        let role = channel.role
        return Binding(
            get: {
                if let frozen = controller.recordingSlate { return frozen.cameraClip(role) }
                return controller.settings.slate.cameraClip(role)
            },
            set: { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if role == .a { controller.settings.slate.cameraClipA = trimmed }
                else { controller.settings.slate.cameraClipB = trimmed }
            })
    }

    private func stat(_ title: String, _ value: Int, alert: Bool = false) -> some View {
        VStack(alignment: .leading) {
            Text(title).foregroundStyle(.secondary)
            Text("\(value)").font(.system(.title3, design: .monospaced))
                .foregroundStyle(alert ? .red : .primary)
        }
    }
}

/// Live picture of one camera with REC / signal badges and the red recording frame.
struct CameraScreen: View {
    @ObservedObject var channel: CameraChannel
    var showWaveform = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            PreviewView(renderer: channel.preview)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                // Luma waveform over the lower part of the picture.
                .overlay {
                    if showWaveform { WaveformOverlay(model: channel.preview.waveform) }
                }
                // Red frame around the picture while this camera is recording.
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.red, lineWidth: 4)
                        .opacity(channel.isRecording ? 1 : 0)
                        .animation(.easeInOut(duration: 0.15), value: channel.isRecording)
                )
            HStack(spacing: 6) {
                if channel.isRecording { Badge(text: "● REC", color: .red) }
                if !channel.hasSource {
                    Badge(text: "Unassigned", color: .gray)
                } else if !channel.hasSignal {
                    Badge(text: "No signal", color: .orange)
                }
            }
            .padding(8)
        }
    }
}
