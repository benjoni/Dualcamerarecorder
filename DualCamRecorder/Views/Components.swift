//
//  Components.swift
//  DualCamRecorder
//

import SwiftUI

/// Horizontal audio peak meter (-60…0 dBFS).
struct AudioMeter: View {
    let db: Float

    var body: some View {
        GeometryReader { geo in
            let level = CGFloat(max(0, min(1, (db + 60) / 60)))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Color.black.opacity(0.5))
                RoundedRectangle(cornerRadius: 2)
                    .fill(LinearGradient(colors: [.green, .green, .yellow, .red],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * level)
            }
        }
        .frame(height: 6)
        .help(db <= -119 ? "Bez zvuku" : String(format: "%.1f dBFS", db))
    }
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(.white)
    }
}

enum DisplayFormat {
    static func bytes(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }

    /// 00:01:23.4 – used for IN/OUT marks.
    static func mark(_ seconds: Double?) -> String {
        guard let seconds else { return "—" }
        let tenths = Int((max(0, seconds) * 10).rounded())
        let s = tenths / 10
        return String(format: "%02d:%02d:%02d.%d", s / 3600, (s / 60) % 60, s % 60, tenths % 10)
    }

    static func remaining(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "—" }
        let m = Int(seconds / 60)
        return m >= 60 ? "≈ \(m / 60) h \(m % 60) min" : "≈ \(m) min"
    }
}
