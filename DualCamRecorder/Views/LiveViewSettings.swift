//
//  LiveViewSettings.swift
//  DualCamRecorder
//
//  "Live view on phones" section of the app Settings (⌘,): on/off, two QR codes / addresses (crew: watch only,
//  slate: can change the slate), number of phones watching, picture quality, new codes.
//

import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

struct LiveViewSettingsSection: View {
    @ObservedObject var model: AppModel
    @ObservedObject var server: LiveViewServer
    /// QR code with the IP address instead of the name (Android phones often cannot open .local).
    @State private var qrByIP = false

    var body: some View {
        Section("Live view on phones") {
            Toggle("Share both cameras with phones on the same Wi-Fi",
                   isOn: Binding(get: { server.isRunning }, set: { model.setLiveView($0) }))

            if server.isRunning, server.nameURL() != nil || !server.ipURLs().isEmpty {
                // Two codes: the whole crew watches; only the slate phone(s) can change scene / shot / take / cards.
                HStack(alignment: .top, spacing: 24) {
                    codeCard(edit: false)
                    codeCard(edit: true)
                }
                .padding(.vertical, 4)
                // Only printed on the sheet (Print…) – the Mac does not need it.
                LabeledContent("Wi-Fi on the printed sheet") {
                    HStack {
                        TextField("Network name", text: $server.wifiName)
                            .textFieldStyle(.roundedBorder).frame(width: 170)
                        TextField("Password (optional)", text: $server.wifiPassword)
                            .textFieldStyle(.roundedBorder).frame(width: 170)
                    }
                }
                HStack(spacing: 16) {
                    if server.nameURL() != nil {
                        Picker("QR codes", selection: $qrByIP) {
                            Text("Name").tag(false)
                            Text("IP address").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                        .help("iPhone opens the name; some Android phones need the IP address")
                    }
                    Spacer()
                    Label("\(server.clientCount) phone\(server.clientCount == 1 ? "" : "s") watching",
                          systemImage: "iphone")
                        .font(.title3)
                }
                if let host = server.hostName, host != LocalName.preferred {
                    Text("For the shorter \(LocalName.preferred): allow DualCamRecorder in System Settings › Privacy & Security › Local Network, then switch the live view off and on (or another Mac on this network already uses the name)")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if server.isRunning {
                Text("The Mac is not connected to a network (Wi-Fi or Ethernet).").foregroundStyle(.red)
            }

            Picker("Picture quality", selection: $server.quality) {
                ForEach(LiveViewQuality.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(server.quality.summary + (server.quality == .high ? " – needs a good Wi-Fi" : ""))
                .font(.caption).foregroundStyle(.secondary)

            if let error = server.error {
                Text(error).foregroundStyle(.red)
            }
            Text("Phones open the page in their web browser – no app needed. Pictures are streamed only while a phone is watching and never slow down recording. The first time, allow incoming connections when macOS asks.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// One code: title, QR code, address, new code. `edit` = the slate code (can change the slate).
    private func codeCard(edit: Bool) -> some View {
        let nameURL = server.nameURL(edit: edit)
        let ipURLs = server.ipURLs(edit: edit)
        let qrURL = qrByIP ? ipURLs.first : (nameURL ?? ipURLs.first)
        return VStack(alignment: .leading, spacing: 8) {
            Label(edit ? "Slate – can change the slate" : "Crew – watch only",
                  systemImage: edit ? "square.and.pencil" : "eye")
                .font(.headline)
                .foregroundStyle(edit ? Color.orange : Color.primary)
            if let qrURL, let qr = Self.qrCode(qrURL) {
                Image(decorative: qr, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 150, height: 150)
                    .padding(8)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
            }
            Text(edit ? "For the script supervisor / 2nd AC: scene, shot, take and card numbers can be changed on the phone."
                      : "For everyone on set: both cameras and the slate, nothing can be changed.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !edit {
                // Crew pictures can carry a watermark (the slate phones always get clean pictures).
                Toggle("Watermark", isOn: $server.crewWatermark)
                    .help("Text over the whole picture on crew phones – it is in every screenshot or screen recording")
                if server.crewWatermark {
                    TextField(Watermark.defaultText, text: $server.crewWatermarkText)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                        .help("E.g. the production name – empty: \(Watermark.defaultText)")
                }
            }
            if let nameURL {
                Text(nameURL).font(.caption.monospaced().weight(.semibold)).textSelection(.enabled)
            }
            ForEach(ipURLs, id: \.self) { address in
                Text(address).font(.caption.monospaced()).textSelection(.enabled)
            }
            HStack {
                Button("Print…") {
                    guard let qrURL else { return }
                    LiveViewPrint.print(.init(edit: edit, url: qrURL,
                                              project: model.projects.current?.project.name ?? "",
                                              wifiName: server.wifiName, wifiPassword: server.wifiPassword,
                                              watermark: !edit && server.crewWatermark))
                }
                .help("A4 sheet with this QR code, the Wi-Fi and three steps – print it or save it as PDF")
                Button("New code") { edit ? server.regenerateEditKey() : server.regenerateKey() }
                    .help("Old links and QR codes of this code stop working")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func qrCode(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}
