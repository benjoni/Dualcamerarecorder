//
//  EditSequenceList.swift
//  DualCamRecorder
//
//  Right side of the Edit tab: the project's sequences (cut passages). Click shows one on the timeline,
//  New starts an empty one; double-click renames, the context menu duplicates / deletes.
//

import SwiftUI

struct EditSequenceList: View {
    @ObservedObject var timeline: EditTimeline
    @ObservedObject var edit: EditPlayer

    @State private var renaming: EditSequence.ID?
    @State private var newName = ""
    @FocusState private var nameFocused: Bool
    @State private var deleting: EditSequence?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Sequences").font(.headline)
                Spacer()
                Button {
                    show { timeline.newSequence() }
                } label: {
                    Label("New", systemImage: "plus")
                }
                .help("New empty sequence – cut another passage (⌥⌘N)")
                .keyboardShortcut("n", modifiers: [.command, .option])
            }
            .padding(.horizontal, 10).padding(.top, 10)

            Text("Click shows it on the timeline · double-click renames")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.top, 4)

            List(selection: Binding(
                get: { timeline.currentID },
                set: { id in if let id { show { timeline.select(id) } } })) {
                ForEach(timeline.sequences) { sequence in
                    row(sequence).tag(sequence.id)
                }
            }
            .contextMenu(forSelectionType: EditSequence.ID.self) { ids in
                if let id = ids.first, let sequence = timeline.sequences.first(where: { $0.id == id }) {
                    Button("Rename") { startRename(sequence) }
                    Button("Duplicate") { show { timeline.duplicate(id) } }
                    Divider()
                    Button(timeline.sequences.count == 1 ? "Clear" : "Delete…", role: .destructive) { deleting = sequence }
                }
            } primaryAction: { ids in
                if let id = ids.first, let sequence = timeline.sequences.first(where: { $0.id == id }) { startRename(sequence) }
            }
        }
        .confirmationDialog(deleting.map { timeline.sequences.count == 1 ? "Clear “\($0.name)”?" : "Delete “\($0.name)”?" } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { sequence in
            Button(timeline.sequences.count == 1 ? "Clear" : "Delete", role: .destructive) {
                show { timeline.delete(sequence.id) }
            }
        } message: { sequence in
            Text("\(sequence.segments.count) pieces, \(edit.timecode(sequence.duration)). The recordings are not touched; this cannot be undone.")
        }
    }

    private func row(_ sequence: EditSequence) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "film.stack").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                if renaming == sequence.id {
                    TextField("Name", text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFocused)
                        .onSubmit { finishRename(sequence.id) }
                        .onExitCommand { renaming = nil }
                        .onChange(of: nameFocused) { _, focused in if !focused { finishRename(sequence.id) } }
                } else {
                    Text(sequence.name).font(.body.weight(.semibold)).lineLimit(1)
                }
                Text("\(sequence.segments.count) pieces · \(edit.timecode(sequence.duration))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    /// Switching sequences starts the player at the beginning of the new one.
    private func show(_ change: () -> Void) {
        edit.pause()
        edit.seek(to: 0)
        change()
    }

    private func startRename(_ sequence: EditSequence) {
        newName = sequence.name
        renaming = sequence.id
        DispatchQueue.main.async { nameFocused = true }
    }

    private func finishRename(_ id: EditSequence.ID) {
        guard renaming == id else { return }
        timeline.rename(id, to: newName)
        renaming = nil
    }
}
