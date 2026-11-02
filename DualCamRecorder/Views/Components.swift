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
    /// Fixed height (e.g. to match a pop-up button next to it); nil = regular height.
    var height: CGFloat? = nil
    /// Minimum height when `height` is nil.
    var minHeight: CGFloat = 30

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            configuration.label
                .lineLimit(1)
                .frame(width: width.map { max(0, $0 - (height == nil ? 32 : 12)) })
                .padding(.horizontal, height == nil ? 16 : 6)
                .padding(.vertical, height == nil ? 5 : 0)
                .frame(minHeight: height ?? minHeight, maxHeight: height)
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

/// Big rounded button in the look of SegmentGroup (system buttons ignore larger fonts on macOS 26).
struct BigButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BigButton(configuration: configuration)
    }

    private struct BigButton: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .lineLimit(1)
                .padding(.horizontal, 20)
                .frame(minHeight: 44)
                .foregroundStyle(isEnabled ? Color.primary : Color.secondary.opacity(0.6))
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(configuration.isPressed ? 0.45 : 0.25))
                )
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// Label with the icon after the title ("Next ⏭").
struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.title
            configuration.icon
        }
    }
}

/// BENJONI logo – two mirrored B (drawn as a vector, so it is sharp at any size). Fill it with a color.
struct BenjoniLogo: Shape {
    func path(in rect: CGRect) -> Path {
        // Drawn on the original 294 × 245 artwork: stroke 16, bowls with radius 42, bars 29 apart.
        let size = CGSize(width: 294, height: 245)
        let stroke: CGFloat = 16, half = stroke / 2, radius: CGFloat = 42
        var b = Path()   // right B: bar and two bowls (stroke centre lines)
        let bar = 169.0
        b.move(to: CGPoint(x: bar, y: 0))
        b.addLine(to: CGPoint(x: bar, y: size.height))
        for (top, bottom) in [(half, 101 - half), (144 + half, size.height - half)] {
            b.addPath(UnevenRoundedRectangle(bottomTrailingRadius: radius, topTrailingRadius: radius, style: .circular)
                .path(in: CGRect(x: bar, y: top, width: size.width - half - bar, height: bottom - top)))
        }
        var logo = b.strokedPath(StrokeStyle(lineWidth: stroke))
        logo.addPath(logo.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 2 * 146.5, ty: 0)))   // left B, mirrored

        let scale = min(rect.width / size.width, rect.height / size.height)
        let x = rect.midX - size.width * scale / 2, y = rect.midY - size.height * scale / 2
        return logo.applying(CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: x, ty: y))
    }
}
