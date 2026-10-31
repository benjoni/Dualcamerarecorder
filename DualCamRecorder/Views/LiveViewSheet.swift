//
//  LiveViewSheet.swift
//  DualCamRecorder
//
//  "Phones" window: switch the live view on, show the QR code / address and how many phones watch.
//

import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

struct LiveViewSheet: View {
    @ObservedObject var model: AppModel
    @ObservedObject var server: LiveViewServer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Live view on phones").font(.title2.weight(.bold))
                Spacer()
                Toggle("", isOn: Binding(get: { server.isRunning }, set: { model.setLiveView($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.large)
            }

            if server.isRunning, let url = server.urls.first {
                HStack(alignment: .top, spacing: 24) {
                    if let qr = Self.qrCode(url) {
                        Image(decorative: qr, scale: 1)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 220, height: 220)
                            .padding(10)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Scan the QR code with the phone camera, or open:")
                            .foregroundStyle(.secondary)
                        ForEach(server.urls, id: \.self) { address in
                            Text(address)
                                .font(.body.monospaced())
                                .textSelection(.enabled)
                        }
                        Label("\(server.clientCount) phone\(server.clientCount == 1 ? "" : "s") watching",
                              systemImage: "iphone")
                            .font(.title3)
                            .padding(.top, 6)
                        Button("New access code") { server.regenerateKey() }
                            .help("Old links and QR codes stop working")
                    }
                }
            } else if server.isRunning {
                Text("The Mac is not connected to a network (Wi-Fi or Ethernet).").foregroundStyle(.red)
            } else {
                Text("Turn on to let phones on the same Wi-Fi watch both cameras live in their web browser – no app needed.")
                    .foregroundStyle(.secondary)
            }

            if let error = server.error {
                Text(error).foregroundStyle(.red)
            }

            Text("Phones must be on the same Wi-Fi as the Mac. About 5 pictures per second, made from the preview only while a phone is watching – recording is not affected. The first time, allow incoming connections when macOS asks.")
                .font(.callout).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 660)
    }

    static func qrCode(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}
