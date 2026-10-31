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

    var body: some View {
        Section("Live view on phones") {
            Toggle("Share both cameras with phones on the same Wi-Fi",
                   isOn: Binding(get: { server.isRunning }, set: { model.setLiveView($0) }))

            if server.isRunning, let url = server.urls.first {
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
                        ForEach(server.urls, id: \.self) { address in
                            Text(address).font(.callout.monospaced()).textSelection(.enabled)
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
