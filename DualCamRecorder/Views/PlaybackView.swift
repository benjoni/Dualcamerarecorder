//
//  PlaybackView.swift
//  DualCamRecorder
//

import SwiftUI

struct PlaybackView: View {
    @ObservedObject var library: TakeLibrary
    @ObservedObject var player: SyncPlaybackController
    @ObservedObject var settings: AppSettings
    @State private var selection: Take.ID?
    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false

    var body: some View {
        HSplitView {
            takeList
                .frame(minWidth: 300, idealWidth: 340, maxWidth: 440)
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    playerPane(title: "Kamera A", available: player.take?.camA != nil, content: PlayerView(player: player.playerA))
                    playerPane(title: "Kamera B", available: player.take?.camB != nil, content: PlayerView(player: player.playerB))
                }
                transport
                Spacer(minLength: 0)
            }
            .padding()
            .frame(minWidth: 700)
        }
        .onAppear { library.setFolder(settings.playbackFolderURL) }
        .onChange(of: settings.playbackFolderURL) { _, url in library.setFolder(url) }
        .onChange(of: selection) { _, id in
            player.load(library.takes.first { $0.id == id })
        }
        .onChange(of: player.currentTime) { _, t in
            if !isScrubbing { scrubValue = t }
        }
        .onReceive(NotificationCenter.default.publisher(for: .takeFinished)) { _ in library.refresh() }
    }

    private var takeList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Zábery").font(.headline)
                Spacer()
                Button { library.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Obnoviť zoznam")
            }
            .padding(8)
            Text(library.folder?.path ?? "")
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .padding(.horizontal, 8)
            List(library.takes, selection: $selection) { take in
                HStack(spacing: 8) {
                    TakeThumbnail(take: take)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(take.name).font(.body.weight(.semibold)).foregroundStyle(.primary)
                            if let m = take.marks, !m.isEmpty {
                                Image(systemName: "flag.fill").foregroundStyle(.yellow).help("Má IN/OUT")
                            }
                        }
                        HStack(spacing: 6) {
                            Text(take.camA != nil ? "A" : "–").foregroundStyle(take.camA != nil ? Color.green : Color.secondary)
                            Text(take.camB != nil ? "B" : "–").foregroundStyle(take.camB != nil ? Color.green : Color.secondary)
                            Text(DisplayFormat.bytes(take.sizeBytes))
                        }
                        HStack(spacing: 4) {
                            Text(take.modified, style: .date)
                            Text(take.modified, style: .time)
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .tag(take.id)
            }
        }
    }

    private func playerPane(title: String, available: Bool, content: PlayerView) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title3.weight(.bold))
            ZStack {
                content
                if !available {
                    Text(player.take == nil ? "Vyber záber" : "Súbor chýba").foregroundStyle(.secondary)
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .frame(maxWidth: .infinity)
    }

    /// Thin bar under the slider showing the IN–OUT range.
    private var rangeBar: some View {
        GeometryReader { geo in
            let d = max(player.duration, 0.001)
            let lo = CGFloat((player.marks.inPoint ?? 0) / d)
            let hi = CGFloat((player.marks.outPoint ?? d) / d)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                if !player.marks.isEmpty {
                    Capsule().fill(Color.yellow.opacity(0.8))
                        .frame(width: max(2, (hi - lo) * geo.size.width))
                        .offset(x: lo * geo.size.width)
                }
            }
        }
        .frame(height: 4)
        .padding(.horizontal, 110)
    }

    private var markControls: some View {
        HStack(spacing: 10) {
            Button("Nastaviť IN") { player.setIn() }
                .keyboardShortcut("i", modifiers: [])
                .help("IN na aktuálnu snímku (I)")
            Button("Nastaviť OUT") { player.setOut() }
                .keyboardShortcut("o", modifiers: [])
                .help("OUT na aktuálnu snímku (O)")
            Button { player.goToIn() } label: { Label("Na IN", systemImage: "arrow.left.to.line") }
                .disabled(player.marks.inPoint == nil)
            Button { player.goToOut() } label: { Label("Na OUT", systemImage: "arrow.right.to.line") }
                .disabled(player.marks.outPoint == nil)
            Button("Zrušiť") { player.clearMarks() }
                .disabled(player.marks.isEmpty)
            Toggle("Hrať len IN–OUT", isOn: $player.limitToRange)
            Spacer()
            Text("IN \(player.marks.inPoint.map { player.timecode($0) } ?? "—")  ·  OUT \(player.marks.outPoint.map { player.timecode($0) } ?? "—")")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
            if let msg = player.marksMessage {
                Text(msg).font(.caption).foregroundStyle(.red)
            }
        }
        .disabled(player.take == nil)
    }

    private var transport: some View {
        VStack(spacing: 8) {
            HStack {
                Text(player.timecode(isScrubbing ? scrubValue : player.currentTime))
                    .font(.system(.title3, design: .monospaced))
                Slider(value: $scrubValue, in: 0...max(player.duration, 0.001), onEditingChanged: { editing in
                    isScrubbing = editing
                    player.isScrubbing = editing
                    if !editing { player.seek(seconds: scrubValue) }
                })
                .onChange(of: scrubValue) { _, v in
                    if isScrubbing { player.seek(seconds: v) }
                }
                Text(player.timecode(player.duration))
                    .font(.system(.title3, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            rangeBar
            markControls
            HStack(spacing: 14) {
                Button { player.goToStart() } label: { Image(systemName: "backward.end.fill") }
                    .help("Na začiatok")
                Button { player.step(-1) } label: { Image(systemName: "backward.frame.fill") }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .help("O snímku späť (←)")
                Button { player.togglePlay() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 40)
                }
                .keyboardShortcut(.space, modifiers: [])
                .help("Prehrať / pauza (medzerník)")
                Button { player.step(1) } label: { Image(systemName: "forward.frame.fill") }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .help("O snímku vpred (→)")

                Picker("Rýchlosť", selection: $player.rate) {
                    Text("0,5×").tag(Float(0.5))
                    Text("1×").tag(Float(1.0))
                }
                .pickerStyle(.segmented)
                .frame(width: 140)

                Toggle("Zvuk A", isOn: $player.audioA)
                Toggle("Zvuk B", isOn: $player.audioB)

                Spacer()
                if let offset = player.abOffsetMs {
                    Text(String(format: "Rozdiel B−A: %+.1f ms", offset))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(abs(offset) > 1000 * player.frameDuration.seconds ? .red : .secondary)
                }
            }
            .disabled(player.take == nil)
        }
    }
}
