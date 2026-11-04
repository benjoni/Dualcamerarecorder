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
    /// Bigger board (recording tab).
    var large = false

    var body: some View {
        VStack(alignment: .leading, spacing: large ? 8 : 6) {
            HStack(spacing: 0) {
                ForEach(0..<8, id: \.self) { i in
                    Rectangle().fill(i.isMultiple(of: 2) ? Color.white : Color.black)
                }
            }
            .frame(height: large ? 14 : 10)
            .rotationEffect(.degrees(-2))
            HStack {
                Text(slate.production.isEmpty ? "PRODUCTION" : slate.production.uppercased())
                    .lineLimit(1)
                Spacer(minLength: 6)
                if !slate.shootingDay.isEmpty { Text("DAY \(slate.shootingDay)") }
            }
            .font(large ? .body.weight(.bold) : .caption.weight(.bold))
            HStack(alignment: .top, spacing: large ? 20 : 14) {
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
            .font(large ? .title2.weight(.bold) : .caption.weight(.semibold))
            HStack(alignment: .top, spacing: large ? 20 : 14) {
                person("DIRECTOR", slate.director)
                person("DOP", slate.cameraOperator)
            }
        }
        .foregroundStyle(.white)
        .padding(large ? 14 : 10)
        .frame(width: large ? 340 : 250, alignment: .leading)
        .background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(recording ? Color.red : Color.gray.opacity(0.5),
                                                         lineWidth: recording ? 2 : 1))
    }

    private func cell(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: large ? 11 : 9, weight: .bold)).foregroundStyle(.gray)
            Text(value).font(.system(size: large ? 46 : 30, weight: .bold, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.5)
        }
    }

    private func person(_ title: String, _ name: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: large ? 11 : 9, weight: .bold)).foregroundStyle(.gray)
            Text(name.isEmpty ? "–" : name).font(large ? .body.weight(.semibold) : .caption.weight(.semibold))
                .lineLimit(1).truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
    /// Fields grouped in the middle with larger text, also in the compact size (recording tab).
    var centered = false

    /// Grouped layout (recording tab, both sizes).
    private var grouped: Bool { large || centered }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                field("Production", text: $slate.production).frame(maxWidth: grouped ? 180 : .infinity)
                field("Director", text: $slate.director).frame(maxWidth: grouped ? 180 : .infinity)
                field("DoP", text: $slate.cameraOperator).frame(maxWidth: grouped ? 180 : .infinity)
                field("Shooting day", text: $slate.shootingDay).frame(maxWidth: 140)
            }
            .disabled(locked)
            if grouped {
                // Scene · shot · take · EXT / DAY / MOS as one group, centered under the fields.
                GridRow {
                    HStack(alignment: .top, spacing: 16) {
                        sceneField
                        shotField
                        takeField
                        extrasGroup
                    }
                    .gridCellColumns(4)
                    .gridCellAnchor(.top)
                }
                .disabled(locked)
            } else {
                GridRow {
                    sceneField
                    shotField
                    takeField
                    extrasGroup
                }
                .disabled(locked)
            }
            if grouped {
                // Note · Good take as one group, centered like the row above.
                GridRow {
                    HStack(alignment: .top, spacing: 10) {
                        field("Note", text: $slate.note).frame(width: large ? 420 : 380)
                        goodToggle
                    }
                    .gridCellColumns(4)
                    .gridCellAnchor(.top)
                }
            } else {
                GridRow {
                    field("Note", text: $slate.note)
                        .gridCellColumns(3)
                    goodToggle
                }
            }
        }
    }

    private var sceneField: some View {
        field("Scene", text: Binding(get: { slate.scene },
                                     set: { v in if let setScene { setScene(v) } else { slate.scene = v } }))
            .frame(maxWidth: grouped ? 75 : 110)
    }

    private var shotField: some View {
        field("Shot", text: Binding(get: { slate.shot },
                                    set: { v in if let setShot { setShot(v) } else { slate.shot = v } }))
            .frame(maxWidth: grouped ? 75 : 110)
    }

    private var takeField: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Take").font(grouped ? .body : .callout).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                styled(TextField("", value: $slate.take, format: .number))
                    .frame(width: grouped ? 80 : 56)
                Stepper("", value: $slate.take, in: 1...999).labelsHidden()
            }
        }
    }

    @ViewBuilder
    private var goodToggle: some View {
        let toggle = SegmentGroup {
            Toggle(isOn: $slate.good) {
                Label("Good take", systemImage: slate.good ? "star.fill" : "star")
            }
            .help("Good (circled) take")
        }
        if grouped {
            // An empty title line like the fields have, and the field's height (group padding 2 + 2):
            // the box sits exactly level with the Note field.
            VStack(alignment: .leading, spacing: 2) {
                Text(" ").font(.body)
                toggle.toggleStyle(SegmentToggleStyle(width: large ? 180 : 160, height: fieldHeight - 4))
            }
        } else {
            toggle
                .toggleStyle(SegmentToggleStyle(width: 150, minHeight: 30))
                .padding(.top, 14)
        }
    }

    /// Height of the text fields in the grouped layout (BigTextFieldStyle).
    private var fieldHeight: CGFloat { large ? 40 : 32 }

    /// EXT / DAY / MOS.
    @ViewBuilder
    private var extrasGroup: some View {
        if grouped {
            // An empty title line like the fields have, and the fields' height: level with Scene / Shot / Take.
            VStack(alignment: .leading, spacing: 2) {
                Text(" ").font(.body)
                HStack(spacing: 10) {
                    boxMenu(slate.location.title) {
                        Picker("", selection: $slate.location) {
                            ForEach(SlateInfo.Location.allCases) { Text($0.title).tag($0) }
                        }
                    }
                    boxMenu(slate.timeOfDay.title) {
                        Picker("", selection: $slate.timeOfDay) {
                            ForEach(SlateInfo.TimeOfDay.allCases) { Text($0.title).tag($0) }
                        }
                    }
                    mosToggle.toggleStyle(SegmentToggleStyle(width: large ? 106 : 96, height: fieldHeight - 4))
                }
            }
        } else {
            HStack(spacing: 10) {
                Picker("", selection: $slate.location) {
                    ForEach(SlateInfo.Location.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().frame(width: 90)
                Picker("", selection: $slate.timeOfDay) {
                    ForEach(SlateInfo.TimeOfDay.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().frame(width: 90)
                mosToggle.toggleStyle(SegmentToggleStyle(width: 86, height: 24))   // + 2 pt group padding = like EXT / DAY
            }
            .padding(.top, 14)
        }
    }

    private var mosToggle: some View {
        SegmentGroup {
            Toggle(isOn: $slate.mos) {
                Label("MOS", systemImage: "speaker.slash")
            }
            .help("Without sound")
        }
    }

    /// Pop-up menu drawn like the text fields next to it (same height, fill and border).
    private func boxMenu<Items: View>(_ title: String, @ViewBuilder items: () -> Items) -> some View {
        Menu {
            items().pickerStyle(.inline).labelsHidden()
        } label: {
            HStack(spacing: 6) {
                Text(title)
                Image(systemName: "chevron.up.chevron.down").font(.caption)
            }
            .frame(width: large ? 110 : 96, height: fieldHeight)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.15)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.gray.opacity(0.35)))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(grouped ? .body : .callout).foregroundStyle(.secondary)
            styled(TextField(title, text: text))
        }
    }

    @ViewBuilder
    private func styled<Field: View>(_ field: Field) -> some View {
        if large {
            field.textFieldStyle(BigTextFieldStyle())
        } else if centered {
            field.textFieldStyle(BigTextFieldStyle(height: 32))
        } else {
            field.textFieldStyle(.roundedBorder)
        }
    }
}

/// Tall text field with larger text (rounded-border fields ignore larger fonts / sizes on macOS 26).
struct BigTextFieldStyle: TextFieldStyle {
    var height: CGFloat = 40

    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .frame(minHeight: height)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.15)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.gray.opacity(0.35)))
    }
}

/// Slate section on the recording tab.
struct SlatePanel: View {
    @ObservedObject var controller: RecordingController
    @ObservedObject var settings: AppSettings
    /// Low window: small board and fields, the hint only as a tooltip.
    var compact = false

    /// While recording, show the frozen slate of the running take (with the live note / good flag).
    private var displayedSlate: SlateInfo {
        guard var shown = controller.recordingSlate else { return settings.slate }
        shown.note = settings.slate.note
        shown.good = settings.slate.good
        return shown
    }

    var body: some View {
        // Board at the left edge, fields centered in the window (an invisible board on the right balances it).
        // In a narrower window the invisible board goes and the fields center in the room next to the board –
        // otherwise the whole window content got wider than the window and its left edge was cut off.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 0) {
                board
                Spacer(minLength: 16)
                fields
                Spacer(minLength: 16)
                SlateBoard(slate: displayedSlate, large: !compact).hidden()
            }
            HStack(alignment: .top, spacing: 16) {
                board
                fields.frame(maxWidth: .infinity)
            }
        }
    }

    private var board: some View {
        SlateBoard(slate: displayedSlate, recording: controller.isRecording, large: !compact)
    }

    private var fields: some View {
            VStack(alignment: .center, spacing: 6) {
                HStack {
                    Text("Slate").font(.title3.weight(.semibold))
                    if !compact {
                        Text(slateHint).font(.callout).foregroundStyle(.secondary)
                    }
                    Toggle(isOn: $settings.showCameraSetup) {
                        Label("Camera Settings", systemImage: "camera.aperture")
                    }
                    .toggleStyle(.button)
                    .fixedSize()
                    .padding(.leading, 8)
                    .help("Shows lens, stop, distance, height, tilt … under both cameras – saved with every clip and printed in the PDF report")
                }
                .help(compact ? slateHint : "")
                SlateFields(slate: $settings.slate,
                            locked: controller.slateLocked,
                            setScene: { controller.setSlateScene($0) },
                            setShot: { controller.setSlateShot($0) },
                            large: !compact, centered: true)
                    .font(compact ? .title3 : .title2)
            }
    }

    private var slateHint: String {
        controller.isRecording
            ? "Scene / shot / take are locked while recording – note and “good take” can still be changed."
            : "Take goes up by 1 after each recording; changing scene or shot resets it to 1."
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
                    HStack(spacing: 10) {
                        Text("Camera clip #").foregroundStyle(.secondary).fixedSize()
                        Text("A")
                        TextField("A001C0001", text: $slate.cameraClipA)
                            .textFieldStyle(.roundedBorder).font(.body.monospaced()).frame(width: 170)
                        Text("B").padding(.leading, 6)
                        TextField("B001C0001", text: $slate.cameraClipB)
                            .textFieldStyle(.roundedBorder).font(.body.monospaced()).frame(width: 170)
                        Text("empty = camera did not record").font(.callout).foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading) {
                            Text("Camera A").font(.callout.weight(.semibold))
                            CameraSetupFields(setup: $slate.setupA)
                        }
                        VStack(alignment: .leading) {
                            Text("Camera B").font(.callout.weight(.semibold))
                            CameraSetupFields(setup: $slate.setupB)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    slate.setupA = slate.setupA.completed
                    slate.setupB = slate.setupB.completed
                    onSave(slate)
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        // Wide enough for the slate board, both cameras' setup fields and the clip numbers – a narrower sheet
        // cut its left and right edges off.
        .frame(minWidth: 1100)
    }
}
