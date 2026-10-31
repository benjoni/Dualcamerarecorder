//
//  SlateView.swift
//  DualCamRecorder
//
//  Clapperboard UI: a board-style summary plus the editable slate fields.
//

import SwiftUI

/// Black "clapperboard" summary: scene / shot / take in big digits.
struct SlateBoard: View {
    let slate: SlateInfo
    var recording = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                ForEach(0..<8, id: \.self) { i in
                    Rectangle().fill(i.isMultiple(of: 2) ? Color.white : Color.black)
                }
            }
            .frame(height: 10)
            .rotationEffect(.degrees(-2))
            HStack {
                Text(slate.production.isEmpty ? "PRODUCTION" : slate.production.uppercased())
                    .lineLimit(1)
                Spacer(minLength: 6)
                if !slate.shootingDay.isEmpty { Text("DAY \(slate.shootingDay)") }
            }
            .font(.caption.weight(.bold))
            HStack(alignment: .top, spacing: 14) {
                cell("SCENE", slate.scene.isEmpty ? "–" : slate.scene)
                cell("SHOT", slate.shot.isEmpty ? "–" : slate.shot)
                cell("TAKE", "\(slate.take)")
            }
            HStack(spacing: 8) {
                if slate.location != .none { Text(slate.location.rawValue) }
                if slate.timeOfDay != .none { Text(slate.timeOfDay.rawValue) }
                if slate.mos { Text("MOS") }
                if slate.good { Image(systemName: "star.fill").foregroundStyle(.yellow) }
            }
            .font(.caption.weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(10)
        .frame(width: 250, alignment: .leading)
        .background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(recording ? Color.red : Color.gray.opacity(0.5),
                                                         lineWidth: recording ? 2 : 1))
    }

    private func cell(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 9, weight: .bold)).foregroundStyle(.gray)
            Text(value).font(.system(size: 30, weight: .bold, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.5)
        }
    }
}

/// Editable slate fields.
/// `locked` freezes the fields that identify a take (used while recording); note and "good" stay editable.
struct SlateFields: View {
    @Binding var slate: SlateInfo
    var locked = false
    /// Custom setters (recording resets the take number when scene/shot change).
    var setScene: ((String) -> Void)?
    var setShot: ((String) -> Void)?
    /// Bigger fields with larger text (recording tab).
    var large = false

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                field("Production", text: $slate.production).frame(maxWidth: large ? 180 : .infinity)
                field("Director", text: $slate.director).frame(maxWidth: large ? 180 : .infinity)
                field("DoP", text: $slate.cameraOperator).frame(maxWidth: large ? 180 : .infinity)
                field("Shooting day", text: $slate.shootingDay).frame(maxWidth: 140)
            }
            .disabled(locked)
            GridRow {
                field("Scene", text: Binding(get: { slate.scene },
                                             set: { v in if let setScene { setScene(v) } else { slate.scene = v } }))
                    .frame(maxWidth: large ? 75 : 110)
                field("Shot", text: Binding(get: { slate.shot },
                                             set: { v in if let setShot { setShot(v) } else { slate.shot = v } }))
                    .frame(maxWidth: large ? 75 : 110)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Take").font(large ? .body : .callout).foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        styled(TextField("", value: $slate.take, format: .number))
                            .frame(width: large ? 80 : 56)
                        Stepper("", value: $slate.take, in: 1...999).labelsHidden()
                    }
                }
                HStack(spacing: 10) {
                    Picker("", selection: $slate.location) {
                        ForEach(SlateInfo.Location.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().frame(width: large ? 110 : 90)
                    Picker("", selection: $slate.timeOfDay) {
                        ForEach(SlateInfo.TimeOfDay.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().frame(width: large ? 110 : 90)
                    SegmentGroup {
                        Toggle(isOn: $slate.mos) {
                            Label("MOS", systemImage: "speaker.slash")
                        }
                        .help("Without sound")
                    }
                    .toggleStyle(SegmentToggleStyle(width: large ? 106 : 86, height: large ? 32 : 24))   // + 2 pt group padding = like EXT / DAY
                }
                .controlSize(large ? .extraLarge : .regular)
                .padding(.top, large ? 22 : 14)
            }
            .disabled(locked)
            GridRow {
                field("Note", text: $slate.note)
                    .frame(maxWidth: large ? 560 : .infinity)   // 3 × 180 + spacing
                    .gridCellColumns(3)
                SegmentGroup {
                    Toggle(isOn: $slate.good) {
                        Label("Good take", systemImage: slate.good ? "star.fill" : "star")
                    }
                    .help("Good (circled) take")
                }
                .toggleStyle(SegmentToggleStyle(width: large ? 180 : 150, minHeight: large ? 32 : 30))
                .padding(.top, large ? 22 : 14)
            }
        }
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(large ? .body : .callout).foregroundStyle(.secondary)
            styled(TextField(title, text: text))
        }
    }

    @ViewBuilder
    private func styled<Field: View>(_ field: Field) -> some View {
        if large {
            field.textFieldStyle(BigTextFieldStyle())
        } else {
            field.textFieldStyle(.roundedBorder)
        }
    }
}

/// Tall text field with larger text (rounded-border fields ignore larger fonts / sizes on macOS 26).
struct BigTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .frame(minHeight: 40)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.15)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.gray.opacity(0.35)))
    }
}

/// Slate section on the recording tab.
struct SlatePanel: View {
    @ObservedObject var controller: RecordingController
    @ObservedObject var settings: AppSettings

    /// While recording, show the frozen slate of the running take (with the live note / good flag).
    private var displayedSlate: SlateInfo {
        guard var shown = controller.recordingSlate else { return settings.slate }
        shown.note = settings.slate.note
        shown.good = settings.slate.good
        return shown
    }

    var body: some View {
        // Board at the left edge, fields centered in the window (an invisible board on the right balances it).
        HStack(alignment: .top, spacing: 0) {
            SlateBoard(slate: displayedSlate, recording: controller.isRecording)
            Spacer(minLength: 16)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Slate").font(.title3.weight(.semibold))
                    Text(controller.isRecording
                         ? "Scene / shot / take are locked while recording – note and “good take” can still be changed."
                         : "Take goes up by 1 after each recording; changing scene or shot resets it to 1.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                SlateFields(slate: $settings.slate,
                            locked: controller.slateLocked,
                            setScene: { controller.setSlateScene($0) },
                            setShot: { controller.setSlateShot($0) },
                            large: true)
                    .font(.title2)
            }
            Spacer(minLength: 16)
            SlateBoard(slate: displayedSlate).hidden()
        }
    }
}

/// Sheet for editing a recorded take's slate in the playback tab.
struct SlateEditSheet: View {
    @State var slate: SlateInfo
    let takeName: String
    let onSave: (SlateInfo) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Slate – \(takeName)").font(.title3.weight(.bold))
            HStack(alignment: .top, spacing: 16) {
                SlateBoard(slate: slate)
                VStack(alignment: .leading, spacing: 10) {
                    SlateFields(slate: $slate)
                    HStack(spacing: 16) {
                        Text("Camera clip #").foregroundStyle(.secondary)
                        Text("A")
                        TextField("A001C0001", text: $slate.cameraClipA)
                            .textFieldStyle(.roundedBorder).font(.body.monospaced()).frame(width: 200)
                        Text("B")
                        TextField("B001C0001", text: $slate.cameraClipB)
                            .textFieldStyle(.roundedBorder).font(.body.monospaced()).frame(width: 200)
                        Text("(empty = camera did not record)").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { onSave(slate); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 900)
    }
}
