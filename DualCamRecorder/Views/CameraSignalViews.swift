//
//  CameraSignalViews.swift
//  DualCamRecorder
//
//  Camera timecode, the camera's own REC (CAM REC / CAM STBY) and warnings when the camera and the app
//  do not record together; timecode sync of the two cameras; Project settings section for all of it.
//

import SwiftUI
import AppKit

/// Over the live picture: CAM REC badge (top right), timecode (bottom right), REC mismatch warning (bottom).
struct CameraSignalOverlay: View {
    @ObservedObject var signal: CameraSignalInfo
    /// The app is recording this camera.
    var appRecording: Bool

    var body: some View {
        ZStack {
            VStack {
                HStack {
                    Spacer()
                    switch signal.cameraRec {
                    case .recording:
                        Badge(text: "● CAM REC", color: .red)
                            .help("The camera itself is recording (\(signal.recFromFlag ? "record flag in the SDI signal" : "timecode is running"))")
                    case .stopped:
                        Badge(text: "CAM STBY", color: .gray)
                            .help("The camera itself is not recording (\(signal.recFromFlag ? "record flag in the SDI signal" : "timecode stands"))")
                    case .unknown:
                        EmptyView()
                    }
                }
                Spacer()
                HStack(alignment: .bottom) {
                    Spacer()
                    if let warning {
                        Text(warning)
                            .font(.callout.weight(.bold)).foregroundStyle(.black)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.orange, in: RoundedRectangle(cornerRadius: 5))
                    }
                    Spacer()
                }
            }
            .padding(8)
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    if let tc = signal.timecode {
                        Text(tc.string)
                            .font(.system(.title3, design: .monospaced).weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                            .help("Timecode sent by the camera in the SDI signal – written into the recorded file")
                    }
                }
            }
            .padding(8)
        }
        .allowsHitTesting(signal.timecode != nil || signal.cameraRec != .unknown)
    }

    private var warning: String? {
        switch (appRecording, signal.cameraRec) {
        case (true, .stopped): return "Camera is NOT recording"
        case (false, .recording): return "Camera is recording – the app is not"
        default: return nil
        }
    }
}

/// "TC A/B in sync" / "TC: B 3 frames behind A" – compares the timecodes of the two cameras at the same moment.
struct TimecodeSyncLabel: View {
    @ObservedObject var a: CameraSignalInfo
    @ObservedObject var b: CameraSignalInfo
    var nameA: String
    var nameB: String

    var body: some View {
        if let text {
            Label(text.0, systemImage: text.1 ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(text.1 ? Color.secondary : Color.orange)
                .help("Timecode of both cameras compared at the same moment (jam sync). The pictures are compared by the time they arrived, so ±1 frame is normal for cameras that are not genlocked.")
        }
    }

    /// Text and whether the cameras are in sync (within 1 frame).
    private var text: (String, Bool)? {
        guard let ta = a.timecode, let tb = b.timecode, a.frameDuration > 0,
              abs(a.frameDuration - b.frameDuration) < 0.0001 else { return nil }
        let base = a.base
        let hostFrames = Double(Int64(a.timecodeHostNanos) - Int64(b.timecodeHostNanos)) / 1e9 / a.frameDuration
        let diff = ta.frameNumber(base: base) - tb.frameNumber(base: base) - Int(hostFrames.rounded())
        if abs(diff) <= 1 { return ("TC \(nameA) / \(nameB) in sync", true) }
        let frames = abs(diff)
        let amount = frames >= base * 60 ? Timecode(frameNumber: frames, base: base).string : "\(frames) frames"
        return ("TC: \(nameB) \(amount) \(diff > 0 ? "behind" : "ahead of") \(nameA)", false)
    }
}

/// Project settings: how the camera's REC is read, recording with the camera, SDI data log.
struct CameraTimecodeSettings: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var recorder: RecordingController
    var folder: URL?

    var body: some View {
        // (Two ForEach over the same roles in one Form would share their row identities – plain rows here.)
        recDetectionPicker(.a)
        if settings.twoCameras { recDetectionPicker(.b) }
        Picker("Record with the camera", selection: $settings.cameraTrigger) {
            Text("Off").tag(CameraTrigger.off)
            Text("Camera \(settings.cameraNames.a)").tag(CameraTrigger.a)
            if settings.twoCameras {
                Text("Camera \(settings.cameraNames.b)").tag(CameraTrigger.b)
                Text("Any camera").tag(CameraTrigger.any)
            }
        }
        Text("The camera's timecode (RP188 / VITC in the SDI signal) is shown on the picture and written into the recorded files (timecode track, TC IN – OUT in the slate, CSV and PDF). Its own REC is read from the record flag it sends (e.g. Blackmagic cameras); with Rec Run timecode set in the camera, a running timecode also means recording. \"Record with the camera\" starts and stops the app's REC together with the camera.")
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        ForEach(settings.twoCameras ? [CameraRole.a, .b] : [.a]) { role in
            SDILogRow(signal: recorder.channel(role).signal, channel: recorder.channel(role),
                      name: settings.cameraNames.name(role), folder: folder)
        }
        Text("SDI data log: everything the camera sends besides the picture, written when it changes. Start it, press REC and STOP on the camera a few times, stop it – the file shows where the camera's record flag is.")
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension CameraTimecodeSettings {
    private func recDetectionPicker(_ role: CameraRole) -> some View {
        Picker("Camera \(settings.cameraNames.name(role)) REC from", selection: Binding(
            get: { settings.recDetection(role) },
            set: { settings.setRecDetection($0, for: role) })) {
            ForEach(CameraRecDetection.allCases) { Text($0.title).tag($0) }
        }
    }
}

private struct SDILogRow: View {
    @ObservedObject var signal: CameraSignalInfo
    var channel: CameraChannel
    var name: String
    var folder: URL?

    var body: some View {
        HStack {
            Text("SDI data log – camera \(name)")
            Spacer()
            if let url = signal.sdiLog {
                Text(url.lastPathComponent).font(.callout.monospaced()).foregroundStyle(.red)
                Button("Stop") {
                    channel.setSDILog(nil)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } else {
                Button("Start") { start() }
                    .disabled(folder == nil)
            }
        }
    }

    private func start() {
        guard let folder else { return }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        channel.setSDILog(folder.appendingPathComponent("SDI_LOG_\(TakeNaming.sanitize(name))_\(f.string(from: Date())).TXT"))
    }
}
