//
//  LicenseView.swift
//  DualCamRecorder
//
//  License window (DualCamRecorder → License…, the license line on the welcome screen): this Mac's ID to send
//  to Benjoni, the installed licence and Import License… (or a .dcrlicense file dropped on the window).
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct LicenseView: View {
    @ObservedObject var license = License.shared
    @State private var message: String?
    @State private var messageIsError = false
    @State private var copied = false
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: statusIcon).font(.system(size: 30)).foregroundStyle(statusColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle).font(.title2.weight(.bold))
                    if let detail = statusDetail { Text(detail).foregroundStyle(.secondary) }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("ID of this Mac").font(.callout.weight(.semibold))
                HStack(spacing: 10) {
                    Text(license.machineID)
                        .font(.system(size: 22, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(license.machineID, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                }
                Text("Send this ID to Benjoni to get a license for this Mac. The license works only on this Mac.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button { chooseFile() } label: { Label("Import License…", systemImage: "key") }
                    .controlSize(.large)
                Text("or drop the .dcrlicense file here").foregroundStyle(.secondary)
            }

            if let message {
                Text(message)
                    .foregroundStyle(messageIsError ? Color.orange : Color.green)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Without a valid license you can still open projects, play, edit and export – only recording is off.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: 520, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 3).opacity(dropTargeted ? 1 : 0))
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { install(url) } }
            }
            return true
        }
        .onAppear { license.refresh() }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "dcrlicense") ?? .data]
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        install(url)
    }

    private func install(_ url: URL) {
        if let problem = license.install(from: url) {
            message = problem
            messageIsError = true
        } else {
            message = "License installed."
            messageIsError = false
        }
    }

    // MARK: - Status

    private var statusIcon: String {
        switch license.state {
        case .valid: return (license.daysLeft ?? 99) <= License.warningDays ? "exclamationmark.circle.fill" : "checkmark.seal.fill"
        default: return "xmark.seal.fill"
        }
    }

    private var statusColor: Color {
        switch license.state {
        case .valid: return (license.daysLeft ?? 99) <= License.warningDays ? .orange : .green
        default: return .red
        }
    }

    private var statusTitle: String {
        switch license.state {
        case .valid(let name, _): return "Licensed to \(name)"
        case .missing: return "No license"
        case .invalid: return "License not valid"
        case .otherMac: return "License for another Mac"
        case .expired: return "License expired"
        case .clockSetBack: return "Date was set back"
        }
    }

    private var statusDetail: String? {
        let date = DateFormatter()
        date.dateStyle = .long
        date.timeStyle = .short
        switch license.state {
        case .valid(_, let expires):
            let days = license.daysLeft ?? 0
            let left = days == 0 ? "last day" : "\(days) day\(days == 1 ? "" : "s") left"
            return "Valid until \(date.string(from: expires)) – \(left)"
        case .missing: return "Recording is off until a license is imported."
        case .invalid(let why): return why
        case .otherMac: return "The installed license belongs to a different Mac."
        case .expired(let when): return "Expired \(date.string(from: when)). Recording is off."
        case .clockSetBack: return "Correct the Mac's date and time – recording is off until then."
        }
    }
}

/// One line on the welcome screen: who the licence is for and how long it runs; a click opens the License window.
struct LicenseBadge: View {
    @ObservedObject var license = License.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if license.isRequired {
            Button { openWindow(id: "license") } label: {
                Label(text, systemImage: icon)
                    .foregroundStyle(color)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help("License of this Mac – click for details")
        }
    }

    private var text: String {
        switch license.state {
        case .valid(let name, _):
            let days = license.daysLeft ?? 0
            return days <= License.warningDays ? "License: \(days == 0 ? "last day" : "\(days) days left")" : "Licensed to \(name)"
        case .expired: return "License expired – recording off"
        default: return "No license – recording off"
        }
    }

    private var icon: String { license.isValid ? "checkmark.seal" : "xmark.seal" }

    private var color: Color {
        guard license.isValid else { return .red }
        return (license.daysLeft ?? 99) <= License.warningDays ? .orange : .secondary
    }
}
