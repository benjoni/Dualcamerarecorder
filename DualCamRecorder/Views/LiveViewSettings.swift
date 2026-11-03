//
//  LiveViewSettings.swift
//  DualCamRecorder
//
//  "Live view on phones" section of the app Settings (⌘,): on/off, QR code / address,
//  number of phones watching, picture quality, new access code.
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

            if server.isRunning, let url = qrByIP ? server.ipURLs.first : (server.nameURL ?? server.ipURLs.first) {
                HStack(alignment: .top, spacing: 20) {
                    if let qr = Self.qrCode(url) {
                        Image(decorative: qr, scale: 1)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 170, height: 170)
                            .padding(8)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Scan the QR code with the phone camera, or open:")
                            .foregroundStyle(.secondary)
                        if let nameURL = server.nameURL {
                            Text(nameURL).font(.callout.monospaced().weight(.semibold)).textSelection(.enabled)
                            Text("Stays the same when the router gives the Mac a new IP address")
                                .font(.caption).foregroundStyle(.secondary)
                            if server.hostName != LocalName.preferred {
                                Text("For the shorter \(LocalName.preferred): allow DualCamRecorder in System Settings › Privacy & Security › Local Network, then switch the live view off and on (or another Mac on this network already uses the name)")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        ForEach(server.ipURLs, id: \.self) { address in
                            Text(address).font(.callout.monospaced()).textSelection(.enabled)
                        }
                        if server.nameURL != nil {
                            Picker("QR code", selection: $qrByIP) {
                                Text("Name").tag(false)
                                Text("IP address").tag(true)
                            }
                            .pickerStyle(.segmented)
                            .fixedSize()
                            .help("iPhone opens the name; some Android phones need the IP address")
                        }
                        Label("\(server.clientCount) phone\(server.clientCount == 1 ? "" : "s") watching",
                              systemImage: "iphone")
                            .font(.title3)
                            .padding(.top, 4)
                        Button("New access code") { server.regenerateKey() }
                            .help("Old links and QR codes stop working")
                    }
                }
                .padding(.vertical, 4)
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

    static func qrCode(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}
