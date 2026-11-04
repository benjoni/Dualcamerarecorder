//
//  OverlayView.swift
//  DualCamRecorder
//
//  Overlay tab (O): pick a recorded clip and a frame of it on the left, the live camera goes on top –
//  Mix with opacity, Difference or Wipe. ←/→ step the clip frame, ↑/↓ change the opacity.
//

import SwiftUI
import AVFoundation

struct OverlayView: View {
    @ObservedObject var compositor: OverlayCompositor
    @ObservedObject var library: TakeLibrary
    @ObservedObject var settings: AppSettings
    var screensOnly = false

    /// The clip (one camera of one take) under the live picture.
    struct Clip: Equatable {
        var take: Take
        var role: CameraRole
        var file: URL
        var id: String { "\(take.number)\(role.rawValue)" }
    }
    @State private var clip: Clip?
    /// The two sample pictures (wide shot under, close-up live) – to try the overlay without cameras.
    @State private var demo = false
    @State private var duration: Double = 0
    @State private var fps: Double = 25
    /// Time of the clip frame (seconds, on a frame).
    @State private var time: Double = 0
    @State private var showClips = true
    @State private var searchText = ""

    var body: some View {
        HStack(spacing: 0) {
            if showClips && !screensOnly {
                clipList.frame(width: 330)
                Divider()
            }
            VStack(spacing: screensOnly ? 0 : 10) {
                if !screensOnly { topBar }
                picture
                if !screensOnly { bottomBar }
            }
            .padding(screensOnly ? 0 : 14)
        }
        .background {
            ZStack {
                ShortcutButton(key: .leftArrow) { step(-1) }
                ShortcutButton(key: .rightArrow) { step(1) }
                ShortcutButton(key: .upArrow) { compositor.opacity = min(1, (compositor.opacity * 10).rounded() / 10 + 0.1) }
                ShortcutButton(key: .downArrow) { compositor.opacity = max(0, (compositor.opacity * 10).rounded() / 10 - 0.1) }
                ShortcutButton(key: "l", modifiers: [.command]) { showClips.toggle() }
            }
        }
        .onAppear {
            library.setFolder(settings.playbackFolderURL)
            if !settings.isCameraOn(compositor.liveRole) { compositor.liveRole = settings.activeRoles.first ?? .a }
            if clip == nil && !demo, let latest = library.takes.first, let row = rows([latest]).first { choose(row) }
        }
        .onDisappear { if demo { compositor.setDemoLive(nil); demo = false; clip = nil } }
        .onReceive(NotificationCenter.default.publisher(for: .takeFinished)) { _ in library.refresh() }
        .task(id: "\(demo ? "demo" : clip?.id ?? "")@\(time)") { await loadStill() }
    }

    // MARK: - Picture

    private var picture: some View {
        ZStack {
            PreviewLayerView(layer: compositor.displayLayer)
            if clip == nil && !demo && compositor.liveProblem != nil {
                VStack(spacing: 10) {
                    Image(systemName: "square.on.square").font(.system(size: 44))
                    Text("Choose a clip on the left – the live camera goes on top of it.").font(.title3)
                }
                .foregroundStyle(.secondary)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .overlay {
            if compositor.mode == .wipe {
                // Drag anywhere on the picture to move the wipe line.
                GeometryReader { g in
                    Color.clear.contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                            compositor.wipe = min(1, max(0, v.location.x / g.size.width))
                        })
                }
            }
        }
        .overlay(alignment: .topLeading) {
            if !screensOnly, demo {
                HStack(spacing: 8) {
                    tag("CLIP", "Demo · wide shot", .blue)
                    tag("LIVE", "Demo · close-up (instead of a camera)", .red)
                }
                .padding(10)
            } else if !screensOnly, let clip {
                HStack(spacing: 8) {
                    tag("CLIP", "\(clip.take.name) · Camera \(clip.take.cameraName(clip.role, current: settings.cameraNames)) · \(timecode(time))", .blue)
                    tag("LIVE", "Camera \(settings.cameraNames.name(compositor.liveRole))", .red)
                }
                .padding(10)
            }
        }
        .overlay(alignment: .bottom) {
            if let problem = compositor.liveProblem, clip != nil, !demo {
                Text(problem).font(.callout.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.black.opacity(0.7), in: Capsule())
                    .foregroundStyle(.orange)
                    .padding(10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func tag(_ kind: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Text(kind).font(.caption.weight(.heavy)).padding(.horizontal, 5).background(color, in: RoundedRectangle(cornerRadius: 3))
            Text(text).font(.callout.weight(.semibold).monospacedDigit())
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Controls

    private var topBar: some View {
        HStack(spacing: 16) {
            Button { showClips.toggle() } label: { Label("Clips", systemImage: "sidebar.left") }
                .help("Show / hide the clip list (⌘L)")
            Spacer()
            Text("Live").foregroundStyle(.secondary)
            Picker("Live", selection: $compositor.liveRole) {
                ForEach(settings.activeRoles) { role in
                    Text("Camera \(settings.cameraNames.name(role))").tag(role)
                }
            }
            .labelsHidden().pickerStyle(.segmented).fixedSize()
            .help("Live camera on top of the clip")
            Picker("Mode", selection: $compositor.mode) {
                ForEach(OverlayMode.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden().pickerStyle(.segmented).fixedSize()
            .help("Mix: live over the clip with the opacity below · Difference: black where live and clip match · Wipe: clip left, live right – drag the line")
            Spacer()
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if compositor.mode == .mix {
                HStack(spacing: 12) {
                    Text("Clip").font(.callout.weight(.semibold)).foregroundStyle(.blue)
                    Slider(value: $compositor.opacity, in: 0...1)
                    Text("Live").font(.callout.weight(.semibold)).foregroundStyle(.red)
                    Text("\(Int((compositor.opacity * 100).rounded())) %").font(.body.monospacedDigit()).frame(width: 56, alignment: .trailing)
                    ForEach([0, 25, 50, 75, 100], id: \.self) { p in
                        Button("\(p)") { compositor.opacity = Double(p) / 100 }.buttonStyle(.bordered).controlSize(.small)
                    }
                }
                .help("Opacity of the live camera: 0 = only the clip, 100 = only live (↑ / ↓ by 10 %)")
            } else if compositor.mode == .wipe {
                HStack(spacing: 12) {
                    Text("Clip").font(.callout.weight(.semibold)).foregroundStyle(.blue)
                    Slider(value: $compositor.wipe, in: 0...1)
                    Text("Live").font(.callout.weight(.semibold)).foregroundStyle(.red)
                }
                .help("Wipe line – or drag on the picture")
            }
            HStack(spacing: 10) {
                Button { step(-1) } label: { Image(systemName: "backward.frame.fill") }.help("One frame back (←)")
                Slider(value: Binding(get: { time }, set: { time = snap($0) }), in: 0...max(duration, 0.01))
                    .disabled(clip == nil || demo)
                Button { step(1) } label: { Image(systemName: "forward.frame.fill") }.help("One frame forward (→)")
                Text(timecode(time)).font(.body.monospacedDigit().weight(.semibold))
                if let marks = clip?.take.marks {
                    if let inPoint = marks.inPoint { Button("IN") { time = snap(inPoint) }.help("Go to the IN mark") }
                    if let outPoint = marks.outPoint { Button("OUT") { time = snap(outPoint) }.help("Go to the OUT mark") }
                }
            }
            .disabled(clip == nil)
        }
        .padding(.bottom, 26)   // clear of "Made by BENJONI"
    }

    // MARK: - Clip list

    private func rows(_ takes: [Take]) -> [Clip] {
        takes.flatMap { take in
            [take.camA.map { Clip(take: take, role: .a, file: $0) },
             take.camB.map { Clip(take: take, role: .b, file: $0) }].compactMap { $0 }
        }
    }

    private var clipList: some View {
        let takes = searchText.trimmingCharacters(in: .whitespaces).isEmpty ? library.takes : library.takes.filter { $0.matches(searchText) }
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Clips").font(.headline)
                Spacer()
                Button { library.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh")
            }
            .padding(.horizontal, 10).padding(.top, 10)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search scene, shot, take, camera, note…", text: $searchText).textFieldStyle(.plain)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.gray.opacity(0.15)))
            .padding(8)
            Text("Click a clip – it goes under the live picture").font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 10)
            List(selection: Binding(get: { demo ? "demo" : clip?.id }, set: { id in
                if id == "demo" { chooseDemo() } else if let id, let row = rows(library.takes).first(where: { $0.id == id }) { choose(row) }
            })) {
                Section("Try it without cameras") {
                    HStack(spacing: 8) {
                        Image("DemoWide").resizable().aspectRatio(16 / 9, contentMode: .fit).frame(width: 96, height: 54)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Demo pictures").font(.body.weight(.semibold))
                            Text("Wide shot under, close-up as live").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                    .tag("demo")
                }
                ForEach(TakeLibrary.group(takes)) { group in
                    Section(group.title) {
                        ForEach(rows(group.takes), id: \.id) { row in rowView(row).tag(row.id) }
                    }
                }
            }
            .padding(.bottom, 34)   // clear of "Made by BENJONI"
        }
    }

    private func rowView(_ row: Clip) -> some View {
        HStack(spacing: 8) {
            ClipCameraThumbnail(url: row.file, modified: row.take.modified)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("\(row.take.name) · Camera \(row.take.cameraName(row.role, current: settings.cameraNames))")
                        .font(.body.weight(.semibold))
                    if row.take.slate?.good == true { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                }
                if let slate = row.take.slate { Text(slate.sceneShotTake).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Clip frame

    private func chooseDemo() {
        guard !demo else { return }
        demo = true
        clip = nil
        compositor.setDemoLive(OverlayCompositor.assetPicture(named: "DemoClose"))
    }

    /// New clip: starts at its IN mark (or the first frame).
    private func choose(_ row: Clip) {
        guard row != clip || demo else { return }
        if demo { demo = false; compositor.setDemoLive(nil) }
        clip = row
        Task { @MainActor in
            let asset = AVURLAsset(url: row.file)
            let length = (try? await asset.load(.duration).seconds) ?? 0
            let rate = (try? await asset.loadTracks(withMediaType: .video).first?.load(.nominalFrameRate)).map(Double.init) ?? 25
            guard clip == row else { return }
            duration = max(0, length - 1 / max(rate, 1))
            fps = rate > 0 ? rate : 25
            time = snap(row.take.marks?.firstInPoint ?? 0)
        }
    }

    private func loadStill() async {
        if demo {
            compositor.setStill(OverlayCompositor.assetPicture(named: "DemoWide"), frameDuration: CMTime(value: 1, timescale: 25))
            return
        }
        guard let clip else { compositor.setStill(nil, frameDuration: CMTime(value: 1, timescale: 25)); return }
        let frame = CMTime(value: Int64((time * fps).rounded()), timescale: CMTimeScale(fps.rounded()))
        let still = await compositor.decodeFrame(url: clip.file, at: frame)
        guard !Task.isCancelled else { return }
        compositor.setStill(still, frameDuration: CMTime(value: 1, timescale: CMTimeScale(max(1, fps.rounded()))))
    }

    private func snap(_ t: Double) -> Double { min(max(0, (t * fps).rounded() / fps), duration) }
    private func step(_ frames: Int) { guard clip != nil else { return }; time = snap(time + Double(frames) / fps) }

    private func timecode(_ seconds: Double) -> String {
        let nominal = max(1, Int(fps.rounded()))
        let total = Int((max(0, seconds) * fps).rounded())
        let s = total / nominal
        return String(format: "%02d:%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60, total % nominal)
    }
}

/// Shows an AVSampleBufferDisplayLayer (the composed picture).
struct PreviewLayerView: NSViewRepresentable {
    let layer: CALayer
    func makeNSView(context: Context) -> LayerHostView {
        let view = LayerHostView()
        view.hostedLayer = layer
        return view
    }
    func updateNSView(_ nsView: LayerHostView, context: Context) {
        if nsView.hostedLayer !== layer { nsView.hostedLayer = layer }
    }
    static func dismantleNSView(_ nsView: LayerHostView, coordinator: ()) { nsView.hostedLayer = nil }
}
