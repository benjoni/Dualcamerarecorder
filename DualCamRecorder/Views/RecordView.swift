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
    /// Low window: smaller transport and slate, numbers in one line – more height for the pictures.
    @State private var compact = false
    static let compactBelowHeight: CGFloat = 1050

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
                CameraScreen(channel: controller.channelA, showWaveform: settings.showWaveform, mask: settings.maskA,
                             rehearsal: controller.isRehearsal)
            }
            if settings.isCameraOn(.b) {
                CameraScreen(channel: controller.channelB, showWaveform: settings.showWaveform, mask: settings.maskB,
                             rehearsal: controller.isRehearsal)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) { WriteWarningBanner(recorder: controller) }
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
            HStack(alignment: .top, spacing: 12) {
                if settings.isCameraOn(.a) {
                    CameraPanel(controller: controller, channel: controller.channelA, settings: settings, showWaveform: settings.showWaveform, compact: compact)
                }
                if settings.isCameraOn(.b) {
                    CameraPanel(controller: controller, channel: controller.channelB, settings: settings, showWaveform: settings.showWaveform, compact: compact)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: settings.cameraAOn)
            .animation(.easeInOut(duration: 0.2), value: settings.cameraBOn)
            .background {
                ZStack {
                    ShortcutButton(key: "1", modifiers: [.option]) { controller.toggleCamera(.a) }
                    ShortcutButton(key: "2", modifiers: [.option]) { controller.toggleCamera(.b) }
                }
            }
            WriteWarningBanner(recorder: controller)
            Divider()
            transportBar
            Divider()
            SlatePanel(controller: controller, settings: settings, compact: compact)
            Divider()
            filesAndDisk
            if let error = controller.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(compact ? 10 : 16)
        .onGeometryChange(for: Bool.self) { $0.size.height < Self.compactBelowHeight } action: { compact = $0 }
    }

    /// REC/STOP, IN and OUT side by side with the same height; timer and IN/OUT times below.
    private var transportBar: some View {
        let recording: Bool = {
            if case .recording = controller.state { return true }
            return false
        }()
        let buttonHeight: CGFloat = compact ? 34 : 48
        let timer = VStack(spacing: compact ? 2 : 10) {
            Text(DisplayFormat.duration(controller.elapsed))
                .font(.system(size: compact ? 24 : 30, weight: .semibold, design: .monospaced))
                .foregroundStyle(controller.isRecording ? .red : .primary)
            Text("IN \(DisplayFormat.mark(controller.marks.inPoint))  ·  OUT \(DisplayFormat.mark(controller.marks.outPoint))"
                 + (controller.marks.ranges.count > 1 ? "  ·  \(controller.marks.ranges.count) ranges" : ""))
                .font(.system(compact ? .callout : .title3, design: .monospaced))
                .foregroundStyle(.secondary)
            if settings.isCameraOn(.a) && settings.isCameraOn(.b) {
                TimecodeSyncLabel(a: controller.channelA.signal, b: controller.channelB.signal,
                                  nameA: settings.cameraNames.a, nameB: settings.cameraNames.b)
            }
        }
        let buttons = HStack(alignment: .center, spacing: 10) {
                // Idle: grey with a coloured edge. Running: filled with the colour, shows STOP until it is stopped.
                TransportButton(icon: "record.circle", title: "REC", color: .red,
                                active: controller.isRecording && !controller.isRehearsal,
                                stopping: isStopping, compact: compact, height: buttonHeight) {
                    controller.toggleRecording()
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(isStopping || controller.isRehearsal)

                // Rehearsal: only the app records (the cameras do not); the take is marked "Rehearsal".
                TransportButton(icon: "theatermasks", title: "REHEARSAL", color: .orange,
                                active: controller.isRehearsal,
                                stopping: isStopping, compact: compact, height: buttonHeight) {
                    if controller.isRehearsal { controller.toggleRecording() } else { controller.startRehearsal() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(isStopping || (controller.isRecording && !controller.isRehearsal))
                .help("Rehearsal (⇧⌘R): both pictures are recorded only by the app, marked as a rehearsal – no take number, the cameras' clip numbers stay. STOP ends it.")

                Group {
                    Button { controller.markIn() } label: {
                        Text("IN").font((compact ? Font.title3 : .title2).weight(.bold)).frame(width: compact ? 70 : 90, height: buttonHeight)
                    }
                    .keyboardShortcut("i", modifiers: [.command])
                    .help("Set IN at the current take time (⌘I) – after an OUT it starts another range")
                    Button { controller.markOut() } label: {
                        Text("OUT").font((compact ? Font.title3 : .title2).weight(.bold)).frame(width: compact ? 70 : 90, height: buttonHeight)
                    }
                    .keyboardShortcut("o", modifiers: [.command])
                    .help("Set OUT at the current take time (⌘O) – closes the range")
                }
                .buttonStyle(.bordered)
                .disabled(!recording)

                Button { controller.clearMarks() } label: { Image(systemName: "xmark.circle").font(.title2) }
                    .buttonStyle(.borderless)
                    .help("Remove the last IN / OUT range")
                    .disabled(!recording || controller.marks.isEmpty)
        }
        return Group {
            if compact {
                // One row: buttons, then the timer with IN / OUT.
                HStack(spacing: 24) { buttons; timer }
            } else {
                VStack(spacing: 10) { buttons; timer }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Next / recording file names and disk info, at the bottom under the slate.
    private var filesAndDisk: some View {
        VStack(spacing: 6) {
            Text(takeLabel).font(.body).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if settings.audioInterfaceMode != .off {
                AudioInterfaceStatus(audio: controller.audioInterface, delayMs: settings.audioInterfaceDelayMs)
                    .font(.callout)
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


    /// Two-camera projects: switch camera A or B off for a while – the other fills the screen and records alone.
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
    @ObservedObject var settings: AppSettings
    var showWaveform = false
    var compact = false
    /// Width of the picture: title row and stats line up with it, everything centered
    /// (with one camera the picture is limited by the window height and does not fill the width).
    @State private var pictureWidth: CGFloat?

    /// "Camera A" title. With two cameras it is an ON / OFF button; a camera that is off has no panel,
    /// so its OFF button is shown next to the title of the camera that is still on.
    @ViewBuilder
    private var cameraTitles: some View {
        let role = channel.role
        if settings.twoCameras {
            let other: CameraRole = role == .a ? .b : .a
            HStack(spacing: 8) {
                if other == .a && !settings.isCameraOn(.a) { CameraTitleButton(controller: controller, settings: settings, role: .a) }
                CameraTitleButton(controller: controller, settings: settings, role: role)
                if other == .b && !settings.isCameraOn(.b) { CameraTitleButton(controller: controller, settings: settings, role: .b) }
                if !settings.isCameraOn(other) {
                    Text("Only \(settings.cameraNames.name(role)) records").font(.callout).foregroundStyle(.orange)
                }
            }
        } else {
            Text("Camera \(settings.cameraNames.name(role))").font(.title3.weight(.bold))
        }
    }

    /// Camera on this input (input device is chosen in Project settings).
    private var cameraPicker: some View {
        Picker("", selection: Binding(
            get: { settings.cameraNames.name(channel.role) },
            set: { controller.setCameraName($0, for: channel.role) })) {
            ForEach(settings.cameraChoices(for: channel.role)) { camera in
                Text(camera.title).tag(TakeNaming.sanitize(camera.name))
            }
        }
        .labelsHidden()
        .fixedSize()   // "C · Ronin 4D" never cut
        .disabled(controller.isRecording)
        .help("Camera on this input – its name starts the file name (C → C007_S12_SH3B_T04.MOV). The list is in Project settings.")
    }

    /// Flip · Flop · Mask.
    private var picturButtons: some View {
        HStack {
            FlipFlopButtons(settings: settings, role: channel.role, locked: controller.isRecording)
            FrameMaskButton(settings: settings, role: channel.role)
        }
        .fixedSize()
    }

    /// "Card" · card number · "Cam clip" · clip number field · stepper.
    private func clipNumber(minFieldWidth: CGFloat) -> some View {
        HStack {
            Text("Card").font(.caption).foregroundStyle(.secondary).fixedSize()
            TextField("A001", text: cardBinding)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .frame(width: 70)
                .disabled(controller.isRecording)
                .help("Number of the memory card in this camera (e.g. A001) – stays for the next takes; saved with every clip, in CLIPLOG.CSV and on the phone slate.")
            Text("Cam clip").font(.caption).foregroundStyle(.secondary).fixedSize()
            TextField("A001C0001", text: cameraClipBinding)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .frame(minWidth: minFieldWidth, idealWidth: 190, maxWidth: 230)
                .disabled(controller.isRecording)
                .help("Clip name in the camera's own recording (e.g. A001C0023). Its last number goes up by 1 after every take; saved with the clip.")
            Stepper("",
                    onIncrement: { cameraClipBinding.wrappedValue = CameraClipID.next(cameraClipBinding.wrappedValue) },
                    onDecrement: { cameraClipBinding.wrappedValue = CameraClipID.previous(cameraClipBinding.wrappedValue) })
                .labelsHidden()
                .disabled(controller.isRecording)
        }
    }

    var body: some View {
        VStack(alignment: .center, spacing: 8) {
            // One row when there is room; in a narrower window two rows (title · camera, then the
            // buttons and the clip number) – one row made the window content wider than the window.
            ViewThatFits(in: .horizontal) {
                HStack {
                    cameraTitles
                        .fixedSize()   // never squeezed, even when the picture is narrow
                    Spacer(minLength: 12)
                    cameraPicker
                    picturButtons
                    clipNumber(minFieldWidth: 150)
                }
                VStack(spacing: 6) {
                    HStack {
                        cameraTitles.fixedSize()
                        Spacer(minLength: 12)
                        cameraPicker
                    }
                    HStack {
                        picturButtons
                        Spacer(minLength: 8)
                        clipNumber(minFieldWidth: 110)
                    }
                }
            }
            .frame(maxWidth: pictureWidth ?? .infinity)

            CameraScreen(channel: channel, showWaveform: showWaveform, mask: settings.mask(channel.role),
                         rehearsal: controller.isRehearsal)
                .overlay(alignment: .bottomLeading) {
                    let o = settings.orientation(channel.role)
                    if o.isTurned {
                        Text(o.label).font(.caption.weight(.heavy)).foregroundStyle(.black)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.yellow, in: RoundedRectangle(cornerRadius: 4))
                            .padding(8)
                            .help("The picture is turned – also in the recorded file")
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pictureWidth = $0 }

            if settings.showCameraSetup {
                CameraSetupFields(setup: setupBinding, locked: controller.isRecording)
                    .frame(maxWidth: pictureWidth.map { max($0, Self.infoMinWidth) } ?? .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: compact ? 4 : 8) {
                Text(channel.format?.displayString ?? "Format: —")
                    .font(.system(compact ? .callout : .body, design: .monospaced))
                    .lineLimit(1).truncationMode(.tail)
                // "Audio interface only": the files get the Focusrite's sound, so its meter replaces the camera's.
                ChannelMetersView(meters: channel.meters, compact: compact,
                                  interface: settings.audioInterfaceMode == .insteadOfSDI ? controller.audioInterface : nil)
                if let error = channel.lastError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
            }
            // At least as wide as the numbers – a small picture must not wrap them (that would shrink it further).
            .frame(maxWidth: pictureWidth.map { max($0, Self.infoMinWidth) } ?? .infinity, alignment: .leading)
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

    /// Card number in this camera (frozen value of the running take while recording).
    private var cardBinding: Binding<String> {
        let role = channel.role
        return Binding(
            get: {
                if let frozen = controller.recordingSlate { return frozen.card(role) }
                return controller.settings.slate.card(role)
            },
            set: { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if role == .a { controller.settings.slate.cardA = trimmed }
                else { controller.settings.slate.cardB = trimmed }
            })
    }

    /// Camera setup for the next take (frozen value of the running take while recording).
    private var setupBinding: Binding<CameraSetup> {
        let role = channel.role
        return Binding(
            get: {
                if let frozen = controller.recordingSlate { return frozen.setup(role) }
                return controller.settings.slate.setup(role)
            },
            set: { value in
                if role == .a { controller.settings.slate.setupA = value }
                else { controller.settings.slate.setupB = value }
            })
    }

    static let infoMinWidth: CGFloat = 460
}

/// Audio meter + captured / written / dropped frames – observes only the 10 Hz meters of the input.
struct ChannelMetersView: View {
    @ObservedObject var meters: ChannelMeters
    var compact: Bool
    /// Set: the audio interface's channels are shown instead of the camera's SDI sound.
    var interface: AudioInterfaceCapture? = nil

    var body: some View {
        let stats = meters.stats
        if let interface {
            InterfaceChannelMeters(audio: interface)
        } else {
            AudioMeter(db: meters.audioLevelDB)
        }
        if compact {
            // Numbers in one line.
            HStack(spacing: 14) {
                inlineStat("Captured", stats.framesCaptured)
                inlineStat("Written", stats.framesWritten)
                inlineStat("Dropped in", stats.inputDropped, alert: stats.inputDropped > 0)
                inlineStat("Dropped write", stats.writerDropped, alert: stats.writerDropped > 0)
            }
            .font(.callout)
            .lineLimit(1)
        } else {
            HStack(spacing: 16) {
                stat("Captured", stats.framesCaptured)
                stat("Written", stats.framesWritten)
                stat("Dropped (input)", stats.inputDropped, alert: stats.inputDropped > 0)
                stat("Dropped (write)", stats.writerDropped, alert: stats.writerDropped > 0)
            }
            .font(.callout)
            .lineLimit(1)
        }
    }

    private func inlineStat(_ title: String, _ value: Int, alert: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            Text("\(value)").font(.system(.callout, design: .monospaced).weight(.semibold))
                .foregroundStyle(alert ? .red : .primary)
        }
        .fixedSize()
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
    var mask = FrameMask()
    /// The take is a rehearsal: orange frame and badge, no "camera is not recording" warning.
    var rehearsal = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            PreviewView(renderer: channel.preview)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                // No picture: the BENJONI logo on black instead of an empty / frozen screen.
                .overlay {
                    if !channel.hasSource || !channel.hasSignal {
                        GeometryReader { geo in
                            BenjoniLogo()
                                .fill(Color.white.opacity(0.3))
                                .frame(height: geo.size.height * 0.32)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .background(Color.black)
                    }
                }
                .overlay { if channel.hasSource && channel.hasSignal { FrameMaskOverlay(mask: mask) } }
                .overlay { if channel.hasSource && channel.hasSignal { CameraSignalOverlay(signal: channel.signal, appRecording: channel.isRecording && !rehearsal) } }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                // Luma waveform over the lower part of the picture.
                .overlay {
                    if showWaveform { WaveformOverlay(model: channel.preview.waveform) }
                }
                // Red frame around the picture while this camera is recording.
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(rehearsal ? Color.orange : Color.red, lineWidth: 4)
                        .opacity(channel.isRecording ? 1 : 0)
                        .animation(.easeInOut(duration: 0.15), value: channel.isRecording)
                )
            HStack(spacing: 6) {
                if channel.isRecording {
                    Badge(text: rehearsal ? "● REHEARSAL" : "● REC", color: rehearsal ? .orange : .red)
                }
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

/// Camera title that switches the camera on / off (two-camera projects, ⌥1 / ⌥2).
struct CameraTitleButton: View {
    @ObservedObject var controller: RecordingController
    @ObservedObject var settings: AppSettings
    let role: CameraRole

    var body: some View {
        let on = settings.isCameraOn(role)
        Button { controller.toggleCamera(role) } label: {
            HStack(spacing: 6) {
                Text("Camera \(settings.cameraNames.name(role))")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(on ? Color.primary : Color.secondary)
                Text(on ? "ON" : "OFF")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(on ? Color.green : Color.red)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(on ? Color.green : Color.red, lineWidth: 1))
            }
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.18)))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(controller.isRecording)
        .help("Camera \(settings.cameraNames.name(role)) on / off (⌥\(role == .a ? 1 : 2)) – the other camera fills the screen and records alone")
    }
}

/// Lens / stop / distance / height / tilt … of one camera in one compact row (never wider than the picture).
/// Kept for the next takes until changed; locked while recording (the running take keeps its values).
struct CameraSetupFields: View {
    @Binding var setup: CameraSetup
    var locked = false
    @FocusState private var focused: Int?

    var body: some View {
        // One row when the picture is wide enough, otherwise lens … tilt / filter … WB.
        ViewThatFits(in: .horizontal) {
            row(0..<CameraSetup.fields.count, clear: true)
            VStack(alignment: .leading, spacing: 4) {
                row(0..<5, clear: false)
                row(5..<CameraSetup.fields.count, clear: true)
            }
        }
        .disabled(locked)
        // Leaving a field (or ↵) adds the unit to a bare number (5600 → 5600K).
        .onChange(of: focused) { old, _ in
            if let old { complete(old) }
        }
        .help(locked ? "Camera settings are locked while recording" : "Camera settings – kept for the next takes, saved with the clip, printed in the PDF report")
    }

    private func complete(_ index: Int) {
        let key = CameraSetup.fields[index].0
        let value = CameraSetup.completed(setup[keyPath: key], field: key)
        if value != setup[keyPath: key] { setup[keyPath: key] = value }
    }

    private func row(_ range: Range<Int>, clear: Bool) -> some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(Array(range), id: \.self) { index in
                let f = CameraSetup.fields[index]
                VStack(alignment: .leading, spacing: 2) {
                    // Same left inset as the text inside the field, so the title sits right above the value.
                    Text(f.1).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .padding(.leading, SetupFieldStyle.inset)
                    TextField(f.2, text: Binding(get: { setup[keyPath: f.0] }, set: { setup[keyPath: f.0] = $0 }))
                        .textFieldStyle(SetupFieldStyle())
                        .focused($focused, equals: index)
                        .onSubmit { complete(index) }
                }
                .frame(minWidth: index == 0 ? 90 : 52, maxWidth: index == 0 ? 160 : 80)
            }
            if clear {
                Button { setup = CameraSetup() } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless)
                    .help("Clear the camera settings")
                    .disabled(locked || setup.isEmpty)
                    .padding(.bottom, 3)
            }
        }
    }
}

/// Small field with a known text inset (the system rounded border field has its own).
private struct SetupFieldStyle: TextFieldStyle {
    static let inset: CGFloat = 6

    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(.callout)
            .padding(.horizontal, Self.inset)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.gray.opacity(0.15)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.gray.opacity(0.35)))
    }
}

/// Flip (upside down) / flop (mirrored) of one input – for a camera mounted upside down or shooting through a mirror.
/// Turns the picture on the screen, the monitor, the phones and in the recorded file; locked while recording.
struct FlipFlopButtons: View {
    @ObservedObject var settings: AppSettings
    var role: CameraRole
    var locked: Bool

    var body: some View {
        let o = settings.orientation(role)
        HStack(spacing: 2) {
            toggle("Flip", systemImage: "arrow.up.and.down", on: o.flip,
                   help: "Flip – turn the picture upside down (camera mounted upside down). Also in the recorded file.") {
                var n = o; n.flip.toggle(); settings.setOrientation(n, for: role)
            }
            toggle("Flop", systemImage: "arrow.left.and.right", on: o.flop,
                   help: "Flop – mirror the picture left ↔ right (shooting through a mirror). Also in the recorded file.") {
                var n = o; n.flop.toggle(); settings.setOrientation(n, for: role)
            }
        }
        .disabled(locked)
    }

    private func toggle(_ title: String, systemImage: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.titleOnly)
                .fontWeight(on ? .bold : .regular)
                .frame(minWidth: 30)
                .foregroundStyle(on ? Color.black : Color.primary)
        }
        .buttonStyle(.bordered)
        .tint(on ? .yellow : nil)
        .background(on ? RoundedRectangle(cornerRadius: 5).fill(Color.yellow) : nil)
        .help(help)
        .accessibilityLabel(title)
    }
}

/// REC / REHEARSAL: grey with a coloured edge when idle; filled with the colour and showing STOP while it runs.
/// Draws its own background so the colours stay the same when the window is not active.
private struct TransportButton: View {
    let icon: String
    let title: String
    let color: Color
    let active: Bool
    let stopping: Bool
    let compact: Bool
    let height: CGFloat
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: active ? "stop.fill" : icon)
                    .font(.system(size: compact ? 20 : 26))
                Text(active ? (stopping ? "Saving…" : "STOP") : title)
                    .font((compact ? Font.title3 : .title2).weight(.bold))
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .padding(.horizontal, 8)
            .frame(width: compact ? 150 : 190, height: height)
            .foregroundStyle(active ? Color.white : color)
            .background(active ? color : Color(white: 0.22), in: shape)
            .overlay(shape.strokeBorder(color, lineWidth: 2.5))
            .contentShape(shape)
            .opacity(isEnabled || active ? 1 : 0.35)
        }
        .buttonStyle(.plain)
    }
}

/// Record tab: the audio interface's level (one small meter per channel) or a red note when it is missing.
struct AudioInterfaceStatus: View {
    @ObservedObject var audio: AudioInterfaceCapture
    var delayMs: Int

    var body: some View {
        if let running = audio.running {
            HStack(spacing: 6) {
                Image(systemName: "mic.fill").foregroundStyle(.secondary)
                Text(running.name).foregroundStyle(.secondary).lineLimit(1)
                VStack(spacing: 2) {
                    ForEach(Array(audio.levelsDB.enumerated()), id: \.offset) { index, db in
                        HStack(spacing: 4) {
                            Text("\(index + 1)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            AudioMeter(db: db).frame(width: 90)
                        }
                    }
                }
                if delayMs != 0 {
                    Text(delayMs > 0 ? "+\(delayMs) ms" : "\(delayMs) ms").foregroundStyle(.orange)
                }
            }
            .help("Sound from the audio interface goes into the files of both cameras")
        } else {
            Label(audio.problem ?? "Audio interface not connected", systemImage: "mic.slash.fill")
                .foregroundStyle(.red)
        }
    }
}

/// Under each camera picture in "Audio interface only": one meter per Focusrite channel (1, 2 …), as wide as the
/// camera meter it replaces; red note when the interface is missing.
struct InterfaceChannelMeters: View {
    @ObservedObject var audio: AudioInterfaceCapture

    var body: some View {
        if audio.running != nil {
            VStack(spacing: 2) {
                ForEach(Array(audio.levelsDB.enumerated()), id: \.offset) { index, db in
                    HStack(spacing: 6) {
                        Text("\(index + 1)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 10)
                        AudioMeter(db: db)
                    }
                }
            }
            .help("Sound from \(audio.running?.name ?? "the audio interface") – recorded into this camera's file")
        } else {
            HStack(spacing: 6) {
                Image(systemName: "mic.slash.fill")
                Text("Audio interface not connected").lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.red)
        }
    }
}
