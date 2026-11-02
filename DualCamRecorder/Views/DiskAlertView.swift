//
//  DiskAlertView.swift
//  DualCamRecorder
//
//  Big red warning over the whole window when the recording disk is disconnected during a take,
//  and the orange "Disk too slow" banner on the Record tab.
//

import SwiftUI

struct DiskAlertOverlay: View {
    @ObservedObject var recorder: RecordingController
    private static let red = Color(red: 0.78, green: 0.06, blue: 0.06)

    var body: some View {
        if let alert = recorder.diskAlert {
            ZStack {
                Color.black.opacity(0.55).ignoresSafeArea()
                VStack(spacing: 18) {
                    Image(systemName: "externaldrive.badge.xmark")
                        .font(.system(size: 64, weight: .semibold))
                    Text("Recording disk disconnected")
                        .font(.system(size: 40, weight: .heavy))
                        .multilineTextAlignment(.center)
                    Text("“\(alert.volumeName)” went away – take \(String(format: "%03d", alert.take)) was stopped after \(DisplayFormat.duration(alert.stoppedAfter)).")
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                    if alert.details.isEmpty {
                        ProgressView("Closing the files …").controlSize(.large).tint(.white)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(alert.details, id: \.self) { line in
                                Label(line, systemImage: "circle.fill")
                                    .labelStyle(BulletLabelStyle())
                            }
                        }
                        .font(.title3)
                        .textSelection(.enabled)
                        .frame(maxWidth: 760, alignment: .leading)
                    }
                    Button {
                        recorder.dismissDiskAlert()
                    } label: {
                        Text("OK").font(.title2.weight(.bold)).foregroundStyle(Self.red)
                            .frame(width: 160, height: 44)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                    .disabled(alert.details.isEmpty)
                }
                .foregroundStyle(.white)
                .padding(40)
                .frame(maxWidth: 900)
                .background(RoundedRectangle(cornerRadius: 22).fill(Self.red))
                .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Color.white.opacity(0.8), lineWidth: 3))
                .shadow(radius: 30)
                .padding(40)
            }
            .transition(.opacity)
        }
    }
}

private struct BulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            configuration.icon.font(.system(size: 7))
            configuration.title.fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// "Disk too slow – CamA lost 12 frames": while recording, and after STOP until it is closed or the next REC.
struct WriteWarningBanner: View {
    @ObservedObject var recorder: RecordingController

    var body: some View {
        if let warning = recorder.writeWarning {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(warning).font(.title3.weight(.bold))
                if !recorder.isRecording {
                    Button { recorder.dismissWriteWarning() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .help("Hide")
                }
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Capsule().fill(Color.orange))
            .help("The disk cannot save the pictures fast enough – use a faster disk (SSD) or a lighter codec (ProRes 422 LT)")
            .padding(10)
        }
    }
}
