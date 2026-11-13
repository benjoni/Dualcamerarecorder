//
//  LUTView.swift
//  DualCamRecorder
//
//  "LUT" button above each live picture (Record tab): pick one of the imported LUTs for this camera,
//  import more .cube files (several at once, or dropped on the list), remove them.
//

import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// Yellow with the LUT's name when one is on.
struct LUTButton: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var library = LUTLibrary.shared
    var role: CameraRole
    @State private var open = false

    var body: some View {
        let name = settings.lut(role)
        let on = library.names.contains(name)
        Button { open.toggle() } label: {
            Text(on ? LUTLibrary.title(name) : "LUT")
                .fontWeight(on ? .bold : .regular)
                .lineLimit(1).truncationMode(.middle)
                .frame(minWidth: 30, maxWidth: 160)
                .foregroundStyle(on ? Color.black : Color.primary)
        }
        .buttonStyle(.bordered)
        .background(on ? RoundedRectangle(cornerRadius: 5).fill(Color.yellow) : nil)
        .fixedSize()
        .help(on ? "LUT \(LUTLibrary.title(name)) – on the screen, the monitor and the phones, not in the recorded file. Click to change."
                 : "LUT – show the picture through a viewing LUT (.cube). Only on the screen, the monitor and the phones, not in the recorded file.")
        .accessibilityLabel("LUT")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            LUTPicker(selection: Binding(get: { settings.lut(role) }, set: { settings.setLUT($0, for: role) }),
                      title: "LUT – Camera \(settings.cameraNames.name(role))")
        }
    }
}

/// List of the imported LUTs (Off + every LUT), Import… and remove.
struct LUTPicker: View {
    @Binding var selection: String
    var title: String
    @ObservedObject var library = LUTLibrary.shared
    @State private var message: String?
    @State private var messageIsError = false
    @State private var importing = false
    @State private var dropTargeted = false
    @State private var removing: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    row(name: "", title: "Off")
                    ForEach(library.names, id: \.self) { name in
                        row(name: name, title: LUTLibrary.title(name))
                    }
                    if library.names.isEmpty {
                        Text("No LUTs yet – import .cube files or drop them here.")
                            .font(.callout).foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 6)
                    }
                }
                .padding(4)
            }
            .frame(height: min(CGFloat(library.names.count + 1) * 28 + 12, 300))
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(dropTargeted ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: dropTargeted ? 2 : 1))
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                loadDropped(providers)
                return true
            }

            HStack {
                Button { chooseFiles() } label: { Label("Import LUTs…", systemImage: "square.and.arrow.down") }
                    .disabled(importing)
                if importing { ProgressView().controlSize(.small) }
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([library.folder]) }
                    .controlSize(.small)
            }

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(messageIsError ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("3D or 1D .cube files (DaVinci Resolve, camera makers). Only on the live picture – screen, waveform, monitor and phones. The recorded file stays as the camera sends it; Playback and Edit show it without the LUT.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 380)
        .confirmationDialog("Remove the LUT \"\(LUTLibrary.title(removing ?? ""))\"?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let name = removing {
                    if selection == name { selection = "" }
                    library.remove(name)
                }
                removing = nil
            }
        } message: {
            Text("Projects that use it show the picture without a LUT.")
        }
    }

    private func row(name: String, title: String) -> some View {
        let selected = selection == name || (name.isEmpty && !library.names.contains(selection))
        return HStack(spacing: 4) {
            Button { selection = name } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark")
                        .font(.callout.weight(.bold))
                        .opacity(selected ? 1 : 0)
                        .frame(width: 16)
                    Text(title)
                        .lineLimit(1).truncationMode(.middle)
                        .fontWeight(selected ? .semibold : .regular)
                    Spacer(minLength: 4)
                }
                .frame(maxWidth: .infinity, minHeight: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityAddTraits(selected ? .isSelected : [])
            if !name.isEmpty {
                Button { removing = name } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Remove this LUT from the list")
                    .accessibilityLabel("Remove \(title)")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 4).fill(selected ? Color.accentColor.opacity(0.25) : Color.clear))
        .contextMenu {
            if !name.isEmpty {
                Button("Remove…") { removing = name }
            }
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.title = "Import LUTs"
        panel.prompt = "Import"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        importFiles(panel.urls)
    }

    private func loadDropped(_ providers: [NSItemProvider]) {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { lock.lock(); urls.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { if !urls.isEmpty { importFiles(urls) } }
    }

    private func importFiles(_ urls: [URL]) {
        importing = true
        message = nil
        library.importFiles(urls) { result in
            importing = false
            // One LUT imported: it is used right away.
            if result.imported.count == 1 { selection = result.imported[0] }
            var lines: [String] = []
            if !result.imported.isEmpty {
                lines.append(result.imported.count == 1 ? "Imported \(LUTLibrary.title(result.imported[0]))."
                                                        : "Imported \(result.imported.count) LUTs.")
            }
            for (name, reason) in result.failed { lines.append("Not imported: \(name) – \(reason).") }
            message = lines.joined(separator: "\n")
            messageIsError = !result.failed.isEmpty
        }
    }
}
