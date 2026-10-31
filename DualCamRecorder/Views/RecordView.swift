//
//  RecordView.swift
//  DualCamRecorder
//

import SwiftUI

struct RecordView: View {
    @ObservedObject var controller: RecordingController
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                CameraPanel(controller: controller, channel: controller.channelA)
                CameraPanel(controller: controller, channel: controller.channelB)
            }
            Divider()
            transportBar
            if let error = controller.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding()
    }

    private var transportBar: some View {
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

            VStack(alignment: .leading, spacing: 4) {
                Text(DisplayFormat.duration(controller.elapsed))
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    .foregroundStyle(controller.isRecording ? .red : .primary)
                Text(takeLabel).font(.callout).foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                HStack {
                    Image(systemName: "internaldrive")
                    Text("Voľné: \(DisplayFormat.bytes(controller.freeBytes)) z \(DisplayFormat.bytes(controller.totalBytes))")
                }
                if let free = controller.freeBytes, let total = controller.totalBytes, total > 0 {
                    ProgressView(value: Double(total - free), total: Double(total))
                        .frame(width: 260)
                        .tint(Double(free) / Double(total) < 0.1 ? .red : .accentColor)
                }
                Text("Zostáva nahrávania: \(DisplayFormat.remaining(controller.estimatedRemaining))")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text(settings.recordFolderPath)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: 300, alignment: .trailing)
                    Button("Zmeniť…") { controller.chooseRecordFolder() }
                        .controlSize(.small)
                        .disabled(controller.isRecording)
                }
            }
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
        case .stopping: return "Ukladám…"
        }
    }

    private var takeLabel: String {
        var parts: [String] = []
        if let active = controller.activeTake {
            parts.append("Nahráva sa \(TakeNaming.displayName(take: active))")
        } else {
            parts.append("Ďalší záber: \(TakeNaming.displayName(take: controller.nextTake))")
        }
        if let offset = controller.lastStartOffsetMs, !controller.isRecording {
            parts.append(String(format: "posun štartu B−A: %+.1f ms", offset))
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
                Text("Kamera \(channel.role.rawValue)")
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
            }

            ZStack(alignment: .topLeading) {
                PreviewView(renderer: channel.preview)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                HStack(spacing: 6) {
                    if channel.isRecording { Badge(text: "● REC", color: .red) }
                    if !channel.hasSource {
                        Badge(text: "Nepriradené", color: .gray)
                    } else if !channel.hasSignal {
                        Badge(text: "Bez signálu", color: .orange)
                    }
                }
                .padding(8)
            }

            Text(channel.format?.displayString ?? "Formát: —")
                .font(.system(.callout, design: .monospaced))
            AudioMeter(db: channel.audioLevelDB)
            HStack(spacing: 16) {
                stat("Zachytené", channel.stats.framesCaptured)
                stat("Zapísané", channel.stats.framesWritten)
                stat("Vynechané (vstup)", channel.stats.inputDropped, alert: channel.stats.inputDropped > 0)
                stat("Vynechané (zápis)", channel.stats.writerDropped, alert: channel.stats.writerDropped > 0)
            }
            .font(.caption)
            if let error = channel.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func stat(_ title: String, _ value: Int, alert: Bool = false) -> some View {
        VStack(alignment: .leading) {
            Text(title).foregroundStyle(.secondary)
            Text("\(value)").font(.system(.body, design: .monospaced))
                .foregroundStyle(alert ? .red : .primary)
        }
    }
}
