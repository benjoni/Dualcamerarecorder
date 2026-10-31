//
//  SettingsView.swift
//  DualCamRecorder
//

import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var controller: RecordingController

    var body: some View {
        Form {
            Section("Priečinky") {
                folderRow(title: "Zápis (nahrávanie)", path: settings.recordFolderPath) { settings.recordFolderPath = $0 }
                Toggle("Prehrávať z iného disku / priečinka", isOn: $settings.separatePlaybackFolder)
                if settings.separatePlaybackFolder {
                    folderRow(title: "Čítanie (prehrávanie)", path: settings.playbackFolderPath) { settings.playbackFolderPath = $0 }
                }
                Text("Pri súčasnom nahrávaní a prehrávaní je najbezpečnejšie čítať z iného disku, než na ktorý sa zapisuje.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Záznam") {
                Picker("Kodek", selection: $settings.proResFlavor) {
                    ForEach(ProResFlavor.allCases) { Text($0.title).tag($0) }
                }
                Picker("Zvuk (SDI embedded)", selection: $settings.audioChannels) {
                    Text("Vypnutý").tag(0)
                    Text("2 kanály").tag(2)
                    Text("8 kanálov").tag(8)
                    Text("16 kanálov").tag(16)
                }
                Toggle("Vynútiť 8-bit zachytávanie (inak 10-bit, ak ho zdroj posiela)", isOn: $settings.forceEightBit)
                Button("Použiť zmeny zvuku / bitovej hĺbky (reštart vstupov)") { controller.restartSources() }
                    .disabled(controller.isRecording)
            }

            Section("DeckLink") {
                Text(controller.sdkStatus).font(.callout)
                if controller.devices.isEmpty {
                    Text("Nenašlo sa žiadne zariadenie. Použi „Simulovaný vstup“ na test UI.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(controller.devices, id: \.identifier) { d in
                    Text("\(d.displayName) · \(d.modelName) · id \(d.identifier) · audio max \(d.maxAudioChannels) ch")
                        .font(.caption.monospaced())
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 620)
        .padding()
    }

    private func folderRow(title: String, path: String, set: @escaping (String) -> Void) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title)
                Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button("Vybrať…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.canCreateDirectories = true
                panel.directoryURL = URL(fileURLWithPath: path)
                if panel.runModal() == .OK, let url = panel.url { set(url.path) }
            }
            .disabled(controller.isRecording)
        }
    }
}
