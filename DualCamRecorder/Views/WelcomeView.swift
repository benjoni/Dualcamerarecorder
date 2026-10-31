//
//  WelcomeView.swift
//  DualCamRecorder
//
//  Start page: create, open and edit projects. A new project creates a folder with the same name
//  in the projects location; that folder becomes the recording folder.
//

import SwiftUI
import AppKit

struct WelcomeView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var projects: ProjectStore
    @ObservedObject var settings: AppSettings

    @State private var editing: EditTarget?
    @State private var errorMessage: String?

    enum EditTarget: Identifiable {
        case new
        case edit(ProjectEntry)
        var id: String {
            switch self {
            case .new: return "new"
            case .edit(let e): return e.id
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 330)
                .background(Color.gray.opacity(0.08))
            Divider()
            projectList
        }
        .onAppear { projects.reload() }
        .sheet(item: $editing) { target in
            switch target {
            case .new:
                ProjectEditSheet(title: "New project", entry: nil, location: projects.rootURL) { name, director, dop, notes, location in
                    let entry = try projects.create(name: name, director: director, dop: dop, notes: notes, location: location)
                    model.open(entry)
                }
            case .edit(let entry):
                ProjectEditSheet(title: "Edit project", entry: entry, location: entry.folder.deletingLastPathComponent()) { name, director, dop, notes, _ in
                    let updated = try projects.update(entry, name: name, director: director, dop: dop, notes: notes)
                    model.applyEdited(updated)
                }
            }
        }
    }

    // MARK: - Left side

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "video.badge.waveform")
                    .font(.system(size: 44))
                    .foregroundStyle(.red)
                Text("DualCamRecorder").font(.largeTitle.weight(.bold))
                Text("Two-camera SDI recording and synced playback")
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 30)

            Button {
                editing = .new
            } label: {
                Label("New project…", systemImage: "plus.circle.fill")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut("n", modifiers: [.command])

            Button {
                openExistingFolder()
            } label: {
                Label("Open folder as project…", systemImage: "folder")
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .controlSize(.large)

            VStack(alignment: .leading, spacing: 4) {
                Text("Projects location").font(.callout.weight(.semibold))
                Text(settings.projectsRootPath)
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle)
                Button("Change…") { chooseProjectsLocation() }
            }

            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.callout)
            }
            Spacer()
            Text(model.recorder.sdkStatus)
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
    }

    // MARK: - Project list

    private var projectList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Projects").font(.title2.weight(.bold))
                Spacer()
                Button { projects.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh")
            }
            .padding([.horizontal, .top], 24)
            .padding(.bottom, 12)

            if projects.projects.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "film.stack").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("No projects yet").font(.title3)
                    Text("Create one with “New project…”.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(projects.projects) { entry in
                            ProjectRow(entry: entry,
                                       clipCount: entry.clipCount(names: settings.cameraNames),
                                       onOpen: { model.open(entry) },
                                       onEdit: { editing = .edit(entry) },
                                       onFinder: { projects.showInFinder(entry) },
                                       onRemove: { projects.removeFromList(entry) })
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Actions

    private func openExistingFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Open"
        panel.directoryURL = projects.rootURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let entry = try projects.addExisting(folder: url)
            model.open(entry)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func chooseProjectsLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = projects.rootURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.projectsRootPath = url.path
        projects.reload()
    }
}

/// One project card.
struct ProjectRow: View {
    let entry: ProjectEntry
    let clipCount: Int
    let onOpen: () -> Void
    let onEdit: () -> Void
    let onFinder: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "folder.fill")
                .font(.system(size: 34))
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.project.name).font(.title3.weight(.semibold))
                Text(entry.folder.path)
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 12) {
                    Label("\(clipCount) clip\(clipCount == 1 ? "" : "s")", systemImage: "film")
                    if let day = entry.project.slate?.shootingDay, !day.isEmpty {
                        Label("Day \(day)", systemImage: "calendar")
                    }
                    if !entry.project.director.isEmpty { Text("Director: \(entry.project.director)") }
                    if !entry.project.dop.isEmpty { Text("DoP: \(entry.project.dop)") }
                    if let opened = entry.project.lastOpenedAt {
                        Text("Opened \(opened.formatted(date: .abbreviated, time: .shortened))")
                    }
                }
                .font(.callout).foregroundStyle(.secondary)
                if !entry.project.notes.isEmpty {
                    Text(entry.project.notes).font(.callout).lineLimit(2)
                }
            }
            Spacer()
            HStack(spacing: 8) {
                Button("Edit…", action: onEdit)
                Button(action: onFinder) { Image(systemName: "magnifyingglass") }
                    .help("Show in Finder")
                Menu {
                    Button("Remove from list", role: .destructive, action: onRemove)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Button("Open", action: onOpen)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.12)))
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onOpen)
    }
}

/// Create / edit form. `onSave` throws to show the error inside the sheet.
struct ProjectEditSheet: View {
    let title: String
    let entry: ProjectEntry?
    @State var location: URL
    let onSave: (String, String, String, String, URL) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var director = ""
    @State private var dop = ""
    @State private var notes = ""
    @State private var error: String?

    init(title: String, entry: ProjectEntry?, location: URL,
         onSave: @escaping (String, String, String, String, URL) throws -> Void) {
        self.title = title
        self.entry = entry
        self._location = State(initialValue: location)
        self.onSave = onSave
        _name = State(initialValue: entry?.project.name ?? "")
        _director = State(initialValue: entry?.project.director ?? "")
        _dop = State(initialValue: entry?.project.dop ?? "")
        _notes = State(initialValue: entry?.project.notes ?? "")
    }

    private var folderPreview: String {
        location.appendingPathComponent(ProjectStore.folderName(for: name.isEmpty ? "…" : name)).path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title2.weight(.bold))
            Form {
                TextField("Project name", text: $name)
                TextField("Director", text: $director)
                TextField("DoP", text: $dop)
                TextField("Notes", text: $notes, axis: .vertical)
                    .lineLimit(2...4)
                LabeledContent(entry == nil ? "Folder" : "Folder (renamed with the project)") {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(folderPreview)
                            .font(.callout.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(2).truncationMode(.middle)
                            .textSelection(.enabled)
                        if entry == nil {
                            Button("Change location…") { chooseLocation() }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .controlSize(.large)

            if let error {
                Text(error).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(entry == nil ? "Create" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 620)
    }

    private func save() {
        do {
            try onSave(name, director, dop, notes, location)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func chooseLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = location
        if panel.runModal() == .OK, let url = panel.url { location = url }
    }
}
