//
//  RecordView.swift
//  DualCamRecorder
//

import SwiftUI

struct RecordView: View {
    @ObservedObject var controller: RecordingController
    @ObservedObject var settings: AppSettings
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
            CameraScreen(channel: controller.channelA)
            CameraScreen(channel: controller.channelB)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .background {
            ZStack {
                ShortcutButton(key: "r", modifiers: [.command]) { controller.toggleRecording() }
                ShortcutButton(key: "i", modifiers: [.command]) { controller.markIn() }
                ShortcutButton(key: "o", modifiers: [.command]) { controller.markOut() }
            }
        }
    }

    private var normalBody: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                CameraPanel(controller: controller, channel: controller.channelA)
                CameraPanel(controller: controller, channel: controller.channelB)
            }
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
    private var transportBar: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 24) {
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

                VStack(alignment: .center, spacing: 4) {
                    Text(DisplayFormat.duration(controller.elapsed))
                        .font(.system(size: 30, weight: .semibold, design: .monospaced))
                        .foregroundStyle(controller.isRecording ? .red : .primary)
                    Text(takeLabel).font(.body).foregroundStyle(.secondary)
                }

                markControls
            }

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
                Button("Change…") { controller.chooseRecordFolder() }
                    .disabled(controller.isRecording)
            }
            .font(.callout)
        }
        .frame(maxWidth: .infinity)
    }

    /// IN / OUT marks set while recording (saved with the take, used by playback).
    private var markControls: some View {
        let recording: Bool = {
            if case .recording = controller.state { return true }
            return false
        }()
        return VStack(alignment: .center, spacing: 6) {
            HStack(spacing: 8) {
                Button { controller.markIn() } label: {
                    Text("IN").font(.title2.weight(.semibold)).frame(width: 64, height: 36)
                }
                .keyboardShortcut("i", modifiers: [.command])
                .help("Set IN at the current take time (⌘I)")
                Button { controller.markOut() } label: {
                    Text("OUT").font(.title2.weight(.semibold)).frame(width: 64, height: 36)
                }
                .keyboardShortcut("o", modifiers: [.command])
                .help("Set OUT at the current take time (⌘O)")
                Button { controller.clearMarks() } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless)
                    .help("Clear IN/OUT")
                    .disabled(controller.marks.isEmpty)
            }
            .disabled(!recording)
            Text("IN \(DisplayFormat.mark(controller.marks.inPoint))  ·  OUT \(DisplayFormat.mark(controller.marks.outPoint))")
                .font(.system(.title3, design: .monospaced))
                .foregroundStyle(.secondary)
        }
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

    private var takeLabel: String {
        var parts: [String] = []
        let names = settings.cameraNames
        if let active = controller.activeTake {
            let a = TakeNaming.fileName(take: active, role: .a, slate: controller.recordingSlate, names: names)
            let b = TakeNaming.fileName(take: active, role: .b, slate: controller.recordingSlate, names: names)
            parts.append("Recording \(a) + \(b)")
        } else {
            let a = TakeNaming.fileName(take: controller.nextTake, role: .a, slate: settings.slate, names: names)
            let b = TakeNaming.fileName(take: controller.nextTake, role: .b, slate: settings.slate, names: names)
            parts.append("Next files: \(a) + \(b)")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Camera \(channel.role.rawValue)")
                    .font(.title3.weight(.bold))
                Picker("", selection: Binding(
                    get: { controller.assignedID(channel.role) },
                    set: { controller.assign($0, to: channel.role) })) {
                    ForEach(controller.deviceOptions) { option in
                        Text(option.title).tag(option.id)
                    }
                }
                .labelsHidden()
                .disabled(controller.isRecording)
                Text("Name").font(.caption).foregroundStyle(.secondary)
                TextField("A", text: Binding(
                    get: { channel.role == .a ? controller.settings.cameraNameA : controller.settings.cameraNameB },
                    set: { controller.setCameraName($0, for: channel.role) }))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .disabled(controller.isRecording)
                    .help("Camera name at the start of the file name, e.g. A → A007_S12_SH3B_T04.MOV")
            }

            CameraScreen(channel: channel)

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

    var body: some View {
        ZStack(alignment: .topLeading) {
            PreviewView(renderer: channel.preview)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
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
