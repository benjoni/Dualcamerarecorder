//
//  LiveViewPrint.swift
//  DualCamRecorder
//
//  Print… next to each live view QR code: an A4 sheet (big QR code, project, Wi-Fi, three steps) for the
//  set – printed, or saved as PDF from the print dialog.
//

import SwiftUI
import AppKit
import PDFKit

enum LiveViewPrint {
    struct Sheet {
        var edit: Bool              // slate code (can change the slate) instead of the crew code
        var url: String
        var project: String
        var wifiName: String
        var wifiPassword: String
        var watermark: Bool
    }

    /// Opens the print dialog with the sheet (PDF / printer chosen there).
    @MainActor
    static func print(_ sheet: Sheet) {
        guard let data = pdf(sheet), let document = PDFDocument(data: data) else { return }
        let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo()
        info.paperSize = NSSize(width: 595, height: 842)
        info.orientation = .portrait
        info.jobDisposition = .spool
        guard let operation = document.printOperation(for: info, scalingMode: .pageScaleToFit, autoRotate: false) else { return }
        operation.jobTitle = (sheet.edit ? "Slate" : "Crew") + " live view – " + sheet.project
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.run()
    }

    /// One A4 page as a vector PDF (the QR code as an image).
    @MainActor
    static func pdf(_ sheet: Sheet) -> Data? {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        let renderer = ImageRenderer(content: SheetView(sheet: sheet)
            .frame(width: 595, height: 842)
            .environment(\.colorScheme, .light))
        renderer.render { _, draw in
            context.beginPDFPage(nil)
            draw(context)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    private struct SheetView: View {
        let sheet: Sheet

        var body: some View {
            VStack(spacing: 22) {
                VStack(spacing: 6) {
                    Text(sheet.edit ? "SLATE – LIVE VIEW" : "CREW – LIVE VIEW")
                        .font(.system(size: 34, weight: .heavy))
                        .foregroundStyle(sheet.edit ? Color(red: 0.85, green: 0.45, blue: 0) : .black)
                    if !sheet.project.isEmpty {
                        Text(sheet.project).font(.system(size: 20, weight: .semibold)).foregroundStyle(Color(white: 0.25))
                    }
                    Text(sheet.edit ? "Both cameras live · this code can change scene, shot, take and cards"
                                    : "Both cameras live on your phone · watch only")
                        .font(.system(size: 13)).foregroundStyle(Color(white: 0.35))
                }

                if let qr = LiveViewSettingsSection.qrCode(sheet.url) {
                    Image(decorative: qr, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 320, height: 320)
                }

                VStack(alignment: .leading, spacing: 12) {
                    step(1, sheet.wifiName.isEmpty
                         ? "Join the same Wi-Fi as the DIT Mac."
                         : "Join the Wi-Fi  \(sheet.wifiName)"
                            + (sheet.wifiPassword.isEmpty ? "" : "   ·   password  \(sheet.wifiPassword)"))
                    step(2, "Scan the QR code with the phone camera.")
                    step(3, "The page opens in the web browser – no app needed. Add it to the home screen for next time.")
                }
                .frame(width: 440, alignment: .leading)

                Text(sheet.url)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color(white: 0.4))

                Spacer(minLength: 0)

                Text(sheet.edit
                     ? "For the script supervisor / 2nd AC only – do not hang this sheet up."
                     : (sheet.watermark ? "The pictures carry a watermark. Please do not record or share them."
                                        : "Please do not record or share the pictures."))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(sheet.edit ? Color(red: 0.75, green: 0.1, blue: 0.1) : Color(white: 0.3))
                Text("DualCamRecorder").font(.system(size: 10)).foregroundStyle(Color(white: 0.55))
            }
            .padding(.top, 56)
            .padding(.bottom, 36)
            .frame(width: 595, height: 842)
            .background(Color.white)
        }

        private func step(_ number: Int, _ text: String) -> some View {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("\(number)")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.black))
                Text(text).font(.system(size: 16)).foregroundStyle(.black)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
