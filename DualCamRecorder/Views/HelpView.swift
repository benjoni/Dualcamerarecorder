//
//  HelpView.swift
//  DualCamRecorder
//
//  Help window (Help menu / toolbar, ⌘?): all keyboard shortcuts, badges and symbols, monitor output, file names.
//

import SwiftUI

struct HelpView: View {
    var body: some View {
        ScrollView {
            Self.content
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 520, idealHeight: 760)
    }

    /// Everything the window shows (also drawn by the debug snapshot).
    static var content: some View { HelpView().sections }

    private var sections: some View {
            VStack(alignment: .leading, spacing: 22) {
                Text("DualCamRecorder Help").font(.largeTitle.weight(.bold))

                section("General") {
                    key("⌘N", "New project (project list)")
                    key("⌥⌘,", "Project settings – inputs, camera list, monitor output, codec, audio, backup")
                    key("⌘,", "App settings – projects location, live view on phones, DeckLink devices")
                    key("⇧⌘W", "Waveform over the pictures")
                    key("⌘F", "Screens only / show all controls (a low window also gets a compact Record tab by itself)")
                    key("R  P  E  O", "Record / Playback / Edit / Overlay (not while typing in a field)")
                    key("⌘1 … ⌘4", "Record / Playback / Edit / Overlay (in Screens only)")
                    key("⌘?", "This help")
                }

                section("Record") {
                    key("⌘R", "REC / STOP")
                    key("⌘I  ⌘O", "IN / OUT at the current take time (while recording)")
                    key("⌥1  ⌥2", "Camera A / B on or off – not while recording; the other camera records alone")
                    term("A · Venice ▾", "Menu above each picture: which camera of the project's camera list is on this input. Its name starts the file names (C → C007_…); the camera the other input uses is not offered")
                    term("Camera list", "Project settings: name + model of every camera (A Venice, B Venice, C Ronin 4D …). Add camera / ⊖ removes; renaming a camera renames the input using it")
                    term("Flip  Flop", "Buttons above each picture: Flip turns the picture upside down (camera mounted upside down), Flop mirrors it left ↔ right (shot through a mirror); both = turned by 180°. The screen, monitor, phones and the recorded file are turned; yellow FLIP / FLOP on the picture. Saved in the project, locked while recording")
                    term("Mask", "Button above each picture (Record and Playback): black bars showing a 1.85, 2:1, 2.35 or custom frame (e.g. 1.33, 2.39) over the 16:9 picture, with adjustable opacity. Per camera, saved in the project. Only on the screen – the recorded file, the monitor and the phones keep the full picture")
                    term("Timecode", "The camera's timecode from the SDI signal (RP188 / VITC) – bottom right of the picture. Written into the recorded file as its timecode track (editors find the source timecode), TC IN – OUT in Playback, CSV and the PDF report. Under the timer: whether the timecode of both cameras is in sync")
                    term("CAM REC  CAM STBY", "The camera itself is recording / standing – from the record flag it sends (Blackmagic cameras: in the timecode user bits – Project settings → \"Blackmagic\"), or from a running Rec Run timecode. Orange warning when the app records and the camera does not, or the other way round. Project settings → Record with the camera: REC / STOP of the camera starts and stops the app")
                    term("Camera Settings", "Button next to Slate: fields under both cameras. A bare number gets its unit when you leave the field (or ↵ / REC): Lens 32 → 32mm, Stop 2.8 → T2.8, Distance / Height 3.2 → 3.2 m, Tilt / Shutter 180 → 180°, WB 5600 → 5600K. Text with its own unit (AWB, 1/50, 10 ft) stays; ISO and Filter are not changed")
                }

                section("Playback") {
                    key("Space", "Play / pause")
                    key("←  →", "One frame back / forward")
                    key("↑  ↓", "Previous / next clip (also ⌘←  ⌘→)")
                    key("I  O", "Set IN / OUT at the current frame")
                    key("⌘L", "Show / hide the clip list")
                    key("⇧A  ⇧B", "Add IN → OUT of camera A / B to the edit (no IN / OUT: whole clip)")
                    key("⇧⌘P", "Export PDF clip report")
                }

                section("Edit") {
                    key("+  ↵", "Clip list: add the clip of this camera to the end (IN → OUT, or the whole clip); also double-click")
                    key("⌘L", "Show / hide the clip list")
                    key("⌘K", "Show / hide the sequences (several cut passages)")
                    key("⌥⌘N", "New sequence")
                    key("Space", "Play / pause the whole edit")
                    key("←  →", "One frame back / forward")
                    key("↑  ↓", "Start of this or previous piece / next piece")
                    key("⌥←  ⌥→", "Move the selected piece earlier / later (or drag it)")
                    key("⌫", "Remove the selected piece – the recording stays")
                    key("⌘Z", "Undo the last change")
                    term("Edges", "Drag the left / right edge of a piece to move its IN / OUT")
                    term("Delete clip", "Playback: right-click the clip in the clip list → Move to Trash… – both camera files, the slate and IN / OUT go to the Trash (they can be put back). The confirmation names the sequences that use the clip")
                    term("Playhead", "Click or drag on the ruler above the pieces (or on the empty part of the timeline) – the playhead follows the mouse; grab the red handle or line to drag it, also over the pieces")
                    term("Sequences", "Right side: several cut passages – New starts an empty one. Click shows it on the timeline, double-click renames, right-click: Rename / Duplicate / Delete (the last one is only cleared). Clips are added to the sequence shown; Undo works within it")
                    term("Export MOV…", "The sequence shown, file name <project>_<sequence>.mov; “Clip info in picture” burns in clip and camera")
                    term("EDIT.JSON", "The edit – all sequences – saved in the project folder")
                }

                section("Live view on phones") {
                    term("dualcam.local", "App settings (⌘,): the address and QR code for phones on the same Wi-Fi. The name stays the same when the router gives the Mac a new IP address. Needs Local Network access for DualCamRecorder (macOS asks once); otherwise the Mac's own name (Mac-mini.local) is used")
                    term("IP address", "QR code › IP address: for phones that cannot open .local names (some Android phones)")
                }

                section("Overlay") {
                    term("Overlay", "One frame of a recorded clip with a live camera on top – to line up a new take with an earlier one. Click a clip on the left (it starts at its IN mark); Live picks the camera")
                    key("←  →", "Clip one frame back / forward (also the slider, IN / OUT buttons)")
                    key("↑  ↓", "Mix: opacity of the live camera ± 10 % (0 = only the clip, 100 = only live)")
                    term("Mix", "Live over the clip with the opacity")
                    term("Difference", "Black where live and clip are the same – everything that moved lights up")
                    term("Wipe", "Clip left, live right – drag the yellow line on the picture")
                    term("Monitor", "On the Overlay tab the Blackmagic monitor shows the overlay (full picture)")
                    term("Demo pictures", "Top of the clip list: try the overlay without cameras – a wide shot as the clip, a close-up instead of the live camera")
                    key("⌘L", "Show / hide the clip list")
                }

                section("Recording disk") {
                    sign(Label("Recording disk disconnected", systemImage: "externaldrive.badge.xmark").foregroundStyle(.red).fontWeight(.bold),
                         "The disk was pulled out or ejected during a take: the take stops at once. What reached the disk plays (up to about 2 s before); slate and IN/OUT are saved in Movies › DualCamRecorder Rescue – copy them to the clips")
                    sign(Label("Disk too slow", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).fontWeight(.bold),
                         "Under the pictures: the disk cannot save the frames in time (frames are lost). After STOP it stays as “Last take: …” until the next REC. Use a faster disk (SSD), ProRes 422 LT or H.265")
                }

                section("Badges and symbols") {
                    sign(Badge(text: "● REC", color: .red), "Camera is recording (red frame around the picture)")
                    sign(Badge(text: "● REHEARSAL", color: .orange), "Rehearsal (⇧⌘R): only the app records, the cameras do not – the take is marked Rehearsal, the take number and camera clips stay")
                    sign(Badge(text: "Unassigned", color: .gray), "No input chosen for this camera – Project settings (the screen shows the BENJONI logo)")
                    sign(Badge(text: "No signal", color: .orange), "Input chosen, but no picture is coming in – the screen shows the BENJONI logo")
                    sign(onOff, "Camera on / off – click the title (⌥1 / ⌥2)")
                    sign(Text("Only B records").foregroundStyle(.orange), "One camera is switched off")
                    sign(Badge(text: "LATEST", color: .blue), "The newest clip")
                    sign(Image(systemName: "star.fill").foregroundStyle(.yellow), "Good take")
                    sign(Image(systemName: "flag.fill").foregroundStyle(.yellow), "Clip has IN / OUT")
                    sign(HStack(spacing: 6) { Text("A").foregroundStyle(.green); Text("–") }, "Clip list: file of camera A exists, camera B was off")
                    sign(Text("MOS").fontWeight(.semibold), "Slate mark “without sound” – sound is still recorded (Audio Off in Project settings)")
                    sign(Text("INT / EXT · DAY / NIGHT").fontWeight(.semibold), "Slate marks for the clip log and the PDF report")
                    sign(Label("Camera Settings", systemImage: "camera.aperture"), "Record (next to Slate): camera settings under both cameras – lens, stop, distance, height, tilt, filter, ISO, shutter, WB. Kept for the next takes, saved with every clip, in the PDF report")
                }

                section("Monitor output (Blackmagic monitor)") {
                    term("Project settings", "“Send the picture to a Blackmagic monitor” – on / off. The first device with a video output is used (UltraStudio Monitor 3G); UltraStudio Recorder 3G has no output")
                    sign(Label("Monitor A|C", systemImage: "display"), "Toolbar (only when the output is on): what goes to the monitor – camera A, camera C or both side by side; the menu also shows the output state")
                    sign(Label("Monitor", systemImage: "exclamationmark.triangle"), "Output problem – monitor not connected, or it cannot show the cameras' format")
                    term("Record", "Live picture of the chosen camera(s)")
                    term("Playback", "The clip being played (paused: the last frame stays)")
                    term("Edit", "The cut – always one full picture, the camera choice is not used")
                    term("Picture", "Clean full frame in the cameras' format (e.g. 1080p25, 8-bit 4:2:2) – no buttons, waveform or text")
                }

                section("Numbers") {
                    term("Captured / Written", "Frames received from the camera / frames saved to the file")
                    term("Dropped (input)", "Frames the camera input lost – red when above 0")
                    term("Dropped (write)", "Frames the disk could not save in time – red when above 0 (also the orange “Disk too slow”)")
                    term("Start offset B−A", "After STOP: how much later camera B started than camera A, in milliseconds")
                    term("A/B out of sync", "Playback: the two clips drifted apart by more than one frame")
                    term("IN · OUT · DUR", "Marked points and the length between them. Several ranges: IN starts a range, OUT closes it, the next IN starts another one; Loop IN/OUT plays only these ranges, one after another")
                    term("Loop  NO · IN/OUT · CLIP", "Playback: play once / repeat IN → OUT / repeat the whole clip")
                    term("Recording time left", "Estimate from the free disk space and the current codec")
                }

                section("Files") {
                    term("A005_S12_SH3_T07.MOV", "Camera name A · clip 005 · scene 12 · shot 3 · take 07")
                    term("C005_SLATE.JSON", "Slate of clip 005 (scene, shot, take, good, MOS, note …)")
                    term("C005_MARKS.JSON", "IN / OUT of clip 005")
                    term("CLIPLOG.CSV", "All clips of the project in one table (opens in Excel / Numbers)")
                    term("PROJECT.JSON", "Project details, its settings (camera list, monitor output …) and the last slate")
                    term("EDIT.JSON", "All edit sequences of the project and the one shown")
                    term("<project>_<sequence>.mov", "Exported edit for the director (H.264 1080p)")
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
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
