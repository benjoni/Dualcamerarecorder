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
        .help(db <= -119 ? "No audio" : String(format: "%.1f dBFS", db))
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

/// Invisible button that only provides a keyboard shortcut (used in "screens only" mode,
/// where the visible controls – and their shortcuts – are hidden).
struct ShortcutButton: View {
    let key: KeyEquivalent
    var modifiers: EventModifiers = []
    let action: () -> Void

    var body: some View {
        Button("", action: action)
            .keyboardShortcut(key, modifiers: modifiers)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }
}

/// Toggle drawn like a segment of a segmented control: light gray when on, dark when off.
struct SegmentToggleStyle: ToggleStyle {
    /// Fixed width so several toggles can share the same size (nil = fit the label).
    var width: CGFloat? = nil

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            configuration.label
                .frame(width: width.map { $0 - 32 })
                .padding(.horizontal, 16)
                .padding(.vertical, 5)
                .frame(minHeight: 30)
                .foregroundStyle(configuration.isOn ? Color.primary : Color.secondary)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(configuration.isOn ? Color.gray.opacity(0.55) : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

/// Container that groups SegmentToggleStyle toggles so they look like one segmented control.
struct SegmentGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 2) { content }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.2)))
    }
}
