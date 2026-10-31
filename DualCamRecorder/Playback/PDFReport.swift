//
//  PDFReport.swift
//  DualCamRecorder
//
//  Clip report as PDF, grouped by shooting day: A4 landscape, every day starts on a new page.
//  Each row: mid-clip picture of camera A (and B), clip number, scene / shot / take, good / MOS,
//  INT/EXT, day/night, file names, camera clip IDs, duration, IN / OUT / DUR, recording time, note.
//  Pages are SwiftUI views rendered into a vector PDF context with ImageRenderer.
//

import SwiftUI
import AVFoundation
import AppKit
import UniformTypeIdentifiers

struct ReportOptions {
    /// nil = all shooting days
    var shootingDay: String?
    var includePictures = true
    var onlyGoodTakes = false
}

/// Everything one PDF row needs (pictures already generated).
struct ReportClip: Identifiable {
    let take: Take
    var duration: Double = 0
    var fps: Double = 25
    var pictureA: CGImage?
    var pictureB: CGImage?
    var id: Int { take.number }
    var slate: SlateInfo? { take.slate }
}

enum PDFReport {
    static let pageSize = CGSize(width: 842, height: 595)   // A4 landscape, points
    static let rowsPerPage = 6

    /// Shooting days present in `takes`, natural order ("" = clips without a day, last).
    static func days(in takes: [Take]) -> [String] {
        let days = Set(takes.map(\.shootingDay))
        return days.sorted { a, b in
            if a.isEmpty { return false }
            if b.isEmpty { return true }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
    }

    /// Loads durations and (optionally) mid-clip pictures, oldest day / clip first.
    static func prepare(takes: [Take], options: ReportOptions) async -> [ReportClip] {
        var selected = takes
        if let day = options.shootingDay { selected = selected.filter { $0.shootingDay == day } }
        if options.onlyGoodTakes { selected = selected.filter { $0.slate?.good == true } }
        let order = days(in: selected)
        selected.sort { a, b in
            let da = order.firstIndex(of: a.shootingDay) ?? 0, db = order.firstIndex(of: b.shootingDay) ?? 0
            return da != db ? da < db : a.number < b.number
        }

        var result: [ReportClip] = []
        for take in selected {
            var clip = ReportClip(take: take)
            if let url = take.camA ?? take.camB {
                let asset = AVURLAsset(url: url)
                clip.duration = ((try? await asset.load(.duration)) ?? .zero).seconds
                if let track = try? await asset.loadTracks(withMediaType: .video).first,
                   let fd = try? await track.load(.minFrameDuration), fd.seconds > 0 {
                    clip.fps = 1 / fd.seconds
                }
            }
            if options.includePictures {
                if let a = take.camA {
                    clip.pictureA = await ThumbnailCache.shared.image(url: a, modified: take.modified)?.reportCGImage
                }
                if let b = take.camB {
                    clip.pictureB = await ThumbnailCache.shared.image(url: b, modified: take.modified)?.reportCGImage
                }
            }
            result.append(clip)
        }
        return result
    }

    /// Writes the PDF. Must run on the main thread (SwiftUI rendering).
    @MainActor
    static func write(clips: [ReportClip], production: String, options: ReportOptions, to url: URL) throws {
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        // Pages: each shooting day starts a new page.
        var pages: [(day: String, clips: [ReportClip], dayPage: Int, dayPages: Int)] = []
        for day in days(in: clips.map(\.take)) {
            let dayClips = clips.filter { $0.take.shootingDay == day }
            let chunks = stride(from: 0, to: dayClips.count, by: rowsPerPage).map {
                Array(dayClips[$0..<min($0 + rowsPerPage, dayClips.count)])
            }
            for (i, chunk) in chunks.enumerated() {
                pages.append((day, chunk, i + 1, chunks.count))
            }
        }
        if pages.isEmpty { pages.append(("", [], 1, 1)) }

        let showB = clips.contains { $0.take.camB != nil }
        for (index, page) in pages.enumerated() {
            let view = ReportPage(production: production,
                                  day: page.day,
                                  dayClipCount: clips.filter { $0.take.shootingDay == page.day }.count,
                                  clips: page.clips,
                                  pictures: options.includePictures,
                                  showB: showB,
                                  pageNumber: index + 1,
                                  pageCount: pages.count,
                                  dayPage: page.dayPage,
                                  dayPages: page.dayPages)
                .frame(width: pageSize.width, height: pageSize.height)
                .environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: view)
            renderer.render { _, draw in
                context.beginPDFPage(nil)
                draw(context)
                context.endPDFPage()
            }
        }
        context.closePDF()
    }

    static func timecode(_ seconds: Double, fps: Double) -> String {
        let nominal = max(1, Int(fps.rounded()))
        let total = Int((seconds * fps).rounded())
        let s = total / nominal
        return String(format: "%02d:%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60, total % nominal)
    }
}

private extension NSImage {
    var reportCGImage: CGImage? { cgImage(forProposedRect: nil, context: nil, hints: nil) }
}

// MARK: - Page layout

private struct ReportPage: View {
    let production: String
    let day: String
    let dayClipCount: Int
    let clips: [ReportClip]
    let pictures: Bool
    let showB: Bool
    let pageNumber: Int
    let pageCount: Int
    let dayPage: Int
    let dayPages: Int

    private var dayTitle: String { day.isEmpty ? "No shooting day" : "Shooting day \(day)" }

    private var dateRange: String {
        let dates = clips.compactMap { $0.slate?.recordedAt ?? $0.take.modified }
        guard let first = dates.min() else { return "" }
        return first.formatted(date: .long, time: .omitted)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(production.isEmpty ? "Clip report" : production)
                        .font(.system(size: 18, weight: .bold))
                    Text("\(dayTitle)  ·  \(dateRange)  ·  \(dayClipCount) clips"
                         + (dayPages > 1 ? "  ·  page \(dayPage)/\(dayPages)" : ""))
                        .font(.system(size: 11))
                        .foregroundStyle(Color(white: 0.3))
                }
                Spacer()
                Text("DualCamRecorder")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(white: 0.5))
            }
            .padding(.bottom, 8)
            Rectangle().fill(Color.black).frame(height: 1.5)

            // Column titles
            HStack(spacing: 10) {
                if pictures {
                    Text("Camera A").frame(width: 104, alignment: .leading)
                    if showB { Text("Camera B").frame(width: 104, alignment: .leading) }
                }
                Text("Clip").frame(width: 46, alignment: .leading)
                Text("Scene / Shot / Take").frame(width: 100, alignment: .leading)
                Text("Files · Camera clip").frame(width: 170, alignment: .leading)
                Text("Duration · IN / OUT").frame(width: 96, alignment: .leading)
                Text("Note").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(Color(white: 0.4))
            .padding(.vertical, 5)
            Rectangle().fill(Color(white: 0.7)).frame(height: 0.5)

            ForEach(clips) { clip in
                ReportRow(clip: clip, pictures: pictures, showB: showB)
                Rectangle().fill(Color(white: 0.85)).frame(height: 0.5)
            }
            Spacer(minLength: 0)

            // Footer
            HStack {
                Text("Generated \(Date().formatted(date: .abbreviated, time: .shortened))")
                Spacer()
                Text("Page \(pageNumber) / \(pageCount)")
            }
            .font(.system(size: 8))
            .foregroundStyle(Color(white: 0.45))
        }
        .padding(28)
        .foregroundStyle(Color.black)
        .background(Color.white)
    }
}

private struct ReportRow: View {
    let clip: ReportClip
    let pictures: Bool
    let showB: Bool

    var body: some View {
        let s = clip.slate
        HStack(alignment: .top, spacing: 10) {
            if pictures {
                picture(clip.pictureA)
                if showB { picture(clip.pictureB) }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(String(format: "%03d", clip.take.number)).font(.system(size: 14, weight: .bold))
                if s?.good == true { tag("★ GOOD", Color(red: 0.75, green: 0.55, blue: 0)) }
                if s?.mos == true { tag("MOS", Color(white: 0.4)) }
            }
            .frame(width: 46, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(s?.scene.isEmpty == false ? s!.scene : "–") / \(s?.shot.isEmpty == false ? s!.shot : "–") / \(s.map { String($0.take) } ?? "–")")
                    .font(.system(size: 13, weight: .semibold))
                Text([s?.location.rawValue ?? "", s?.timeOfDay.rawValue ?? ""]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 8))
            }
            .frame(width: 100, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                fileLine("A", clip.take.camA?.lastPathComponent, s?.cameraClipA)
                if clip.take.camB != nil || !(s?.cameraClipB ?? "").isEmpty {
                    fileLine("B", clip.take.camB?.lastPathComponent, s?.cameraClipB)
                }
            }
            .frame(width: 170, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(PDFReport.timecode(clip.duration, fps: clip.fps)).font(.system(size: 9, weight: .semibold, design: .monospaced))
                if let m = clip.take.marks, !m.isEmpty {
                    let lo = m.inPoint ?? 0
                    let hi = m.outPoint ?? clip.duration
                    Text("IN \(PDFReport.timecode(lo, fps: clip.fps))").font(.system(size: 8, design: .monospaced))
                    Text("OUT \(PDFReport.timecode(hi, fps: clip.fps))").font(.system(size: 8, design: .monospaced))
                    Text("DUR \(PDFReport.timecode(max(0, hi - lo), fps: clip.fps))").font(.system(size: 8, design: .monospaced))
                }
                if let rec = s?.recordedAt ?? Optional(clip.take.modified) {
                    Text(rec.formatted(date: .omitted, time: .shortened)).font(.system(size: 8))
                        .foregroundStyle(Color(white: 0.35))
                }
            }
            .frame(width: 96, alignment: .leading)

            Text(s?.note ?? "")
                .font(.system(size: 9))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(5)
        }
        .padding(.vertical, 5)
        .frame(height: 74, alignment: .top)
    }

    private func picture(_ image: CGImage?) -> some View {
        ZStack {
            Rectangle().fill(Color(white: 0.9))
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
            } else {
                Text("—").font(.system(size: 9)).foregroundStyle(Color(white: 0.5))
            }
        }
        .frame(width: 104, height: 58.5)
        .clipShape(RoundedRectangle(cornerRadius: 2))
    }

    private func fileLine(_ cam: String, _ file: String?, _ cameraClip: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(cam): \(file ?? "—")").font(.system(size: 8, design: .monospaced)).lineLimit(1)
            if let cameraClip, !cameraClip.isEmpty {
                Text("  cam clip \(cameraClip)").font(.system(size: 8, weight: .semibold, design: .monospaced)).lineLimit(1)
            }
        }
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 7, weight: .bold))
            .padding(.horizontal, 4).padding(.vertical, 1)
            .foregroundStyle(Color.white)
            .background(RoundedRectangle(cornerRadius: 2).fill(color))
    }
}

// MARK: - Export sheet

struct ExportPDFSheet: View {
    @ObservedObject var library: TakeLibrary
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var day: String = "*"          // "*" = all days
    @State private var includePictures = true
    @State private var onlyGood = false
    @State private var working = false
    @State private var error: String?

    private var days: [String] { PDFReport.days(in: library.takes) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export clip report (PDF)").font(.title2.weight(.bold))
            Form {
                Picker("Shooting days", selection: $day) {
                    Text("All days").tag("*")
                    ForEach(days, id: \.self) { d in
                        Text(d.isEmpty ? "No shooting day" : "Day \(d)").tag(d)
                    }
                }
                Toggle("Include pictures (middle of each clip)", isOn: $includePictures)
                Toggle("Only good takes (★)", isOn: $onlyGood)
                LabeledContent("Clips") {
                    Text("\(selectedCount)")
                }
            }
            .formStyle(.grouped)
            .controlSize(.large)

            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                if working {
                    ProgressView().controlSize(.small)
                    Text("Creating PDF…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") { export() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(working || selectedCount == 0)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 560)
    }

    private var selectedCount: Int {
        library.takes.filter { (day == "*" || $0.shootingDay == day) && (!onlyGood || $0.slate?.good == true) }.count
    }

    private func export() {
        let production = settings.slate.production
        let dayPart = day == "*" ? "All days" : (day.isEmpty ? "No day" : "Day \(day)")
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.directoryURL = library.folder ?? settings.recordFolderURL
        panel.nameFieldStringValue = "\(production.isEmpty ? "Clips" : ProjectStore.folderName(for: production)) – \(dayPart).pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let options = ReportOptions(shootingDay: day == "*" ? nil : day, includePictures: includePictures, onlyGoodTakes: onlyGood)
        let takes = library.takes
        working = true
        error = nil
        Task { @MainActor in
            let clips = await PDFReport.prepare(takes: takes, options: options)
            do {
                try PDFReport.write(clips: clips, production: production, options: options, to: url)
                working = false
                NSWorkspace.shared.open(url)
                dismiss()
            } catch {
                working = false
                self.error = "Could not write the PDF: \(error.localizedDescription)"
            }
        }
    }
}
