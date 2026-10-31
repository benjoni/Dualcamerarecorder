//
//  HelpView.swift
//  DualCamRecorder
//
//  Help window (Help menu / toolbar, ⌘?): all keyboard shortcuts, badges and symbols, file names.
//

import SwiftUI

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("DualCamRecorder Help").font(.largeTitle.weight(.bold))

                section("General") {
                    key("⌘N", "New project (project list)")
                    key("⌥⌘,", "Project settings – cameras, inputs, codec, audio, backup")
                    key("⌘,", "App settings – projects location, live view on phones, DeckLink devices")
                    key("⇧⌘W", "Waveform over the pictures")
                    key("⌘F", "Screens only / show all controls")
                    key("⌘1  ⌘2", "Record / Playback (in Screens only)")
                    key("⌘?", "This help")
                }

                section("Record") {
                    key("⌘R", "REC / STOP")
                    key("⌘I  ⌘O", "IN / OUT at the current take time (while recording)")
                    key("⌥1  ⌥2", "Camera A / B on or off – not while recording; the other camera records alone")
                }

                section("Playback") {
                    key("Space", "Play / pause")
                    key("←  →", "One frame back / forward")
                    key("⌘←  ⌘→", "Previous / next clip")
                    key("I  O", "Set IN / OUT at the current frame")
                    key("⌘L", "Show / hide the clip list")
                    key("⇧⌘P", "Export PDF clip report")
                }

                section("Badges and symbols") {
                    sign(Badge(text: "● REC", color: .red), "Camera is recording (red frame around the picture)")
                    sign(Badge(text: "Unassigned", color: .gray), "No input chosen for this camera – Project settings")
                    sign(Badge(text: "No signal", color: .orange), "Input chosen, but no picture is coming in")
                    sign(onOff, "Camera on / off – click the title (⌥1 / ⌥2)")
                    sign(Text("Only B records").foregroundStyle(.orange), "One camera is switched off")
                    sign(Badge(text: "LATEST", color: .blue), "The newest clip")
                    sign(Image(systemName: "star.fill").foregroundStyle(.yellow), "Good take")
                    sign(Image(systemName: "flag.fill").foregroundStyle(.yellow), "Clip has IN / OUT")
                    sign(HStack(spacing: 6) { Text("A").foregroundStyle(.green); Text("–") }, "Clip list: file of camera A exists, camera B was off")
                    sign(Text("MOS").fontWeight(.semibold), "Slate mark “without sound” – sound is still recorded (Audio Off in Project settings)")
                    sign(Text("INT / EXT · DAY / NIGHT").fontWeight(.semibold), "Slate marks for the clip log and the PDF report")
                }

                section("Numbers") {
                    term("Captured / Written", "Frames received from the camera / frames saved to the file")
                    term("Dropped (input)", "Frames the camera input lost – red when above 0")
                    term("Dropped (write)", "Frames the disk could not save in time – red when above 0")
                    term("Start offset B−A", "After STOP: how much later camera B started than camera A, in milliseconds")
                    term("A/B out of sync", "Playback: the two clips drifted apart by more than one frame")
                    term("IN · OUT · DUR", "Marked points and the length between them")
                    term("Loop  NO · IN/OUT · Clip", "Playback: play once / repeat IN → OUT / repeat the whole clip")
                    term("Recording time left", "Estimate from the free disk space and the current codec")
                }

                section("Files") {
                    term("A005_S12_SH3_T07.MOV", "Camera name A · clip 005 · scene 12 · shot 3 · take 07")
                    term("C005_SLATE.JSON", "Slate of clip 005 (scene, shot, take, good, MOS, note …)")
                    term("C005_MARKS.JSON", "IN / OUT of clip 005")
                    term("CLIPLOG.CSV", "All clips of the project in one table (opens in Excel / Numbers)")
                    term("PROJECT.JSON", "Project details, its settings and the last slate")
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 520, idealHeight: 760)
    }

    private var onOff: some View {
        HStack(spacing: 6) {
            Text("ON").font(.caption.weight(.heavy)).foregroundStyle(.green)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.green, lineWidth: 1))
            Text("OFF").font(.caption.weight(.heavy)).foregroundStyle(.red)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.red, lineWidth: 1))
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title2.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                content()
            }
        }
    }

    private func key(_ keys: String, _ text: String) -> some View {
        GridRow {
            Text(keys)
                .font(.body.monospaced().weight(.semibold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.gray.opacity(0.2)))
                .frame(minWidth: 130, alignment: .leading)
            Text(text)
        }
    }

    private func sign<Symbol: View>(_ symbol: Symbol, _ text: String) -> some View {
        GridRow {
            symbol.frame(minWidth: 130, alignment: .leading)
            Text(text)
        }
    }

    private func term(_ name: String, _ text: String) -> some View {
        GridRow {
            Text(name).font(.body.monospaced()).frame(minWidth: 130, alignment: .leading)
            Text(text)
        }
    }
}
