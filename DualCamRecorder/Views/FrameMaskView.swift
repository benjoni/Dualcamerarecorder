//
//  FrameMaskView.swift
//  DualCamRecorder
//
//  Aspect ratio mask (1.85, 2:1, 2.35, custom) over a 16:9 camera picture – black bars with adjustable opacity.
//  A framing guide on the screen only: the recorded file, the monitor and the phones keep the full picture.
//

import SwiftUI

/// Bars over the picture: top / bottom for a wider format, left / right for a narrower one.
struct FrameMaskOverlay: View {
    var mask: FrameMask
    /// Width ÷ height of the picture under the mask.
    var pictureAspect = 16.0 / 9.0

    var body: some View {
        if let aspect = mask.aspect {
            GeometryReader { geo in
                let size = geo.size
                let frame = Self.frame(in: size, aspect: aspect)
                ZStack(alignment: .topLeading) {
                    // Bars = whole picture minus the masked frame.
                    Path { p in
                        p.addRect(CGRect(origin: .zero, size: size))
                        p.addRect(frame)
                    }
                    .fill(Color.black.opacity(mask.opacity), style: FillStyle(eoFill: true))
                    // Thin edge line, visible also with low opacity.
                    Path { p in p.addRect(frame) }
                        .stroke(Color.white.opacity(0.45), lineWidth: 1)
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// The masked frame centered in the picture.
    static func frame(in size: CGSize, aspect: Double) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let picture = Double(size.width / size.height)
        if aspect >= picture {
            let h = size.width / aspect
            return CGRect(x: 0, y: (size.height - h) / 2, width: size.width, height: h)
        } else {
            let w = size.height * aspect
            return CGRect(x: (size.width - w) / 2, y: 0, width: w, height: size.height)
        }
    }
}

/// "Mask" button of one camera: ratio and opacity in a popover. Yellow (with the ratio) when a mask is on.
struct FrameMaskButton: View {
    @ObservedObject var settings: AppSettings
    var role: CameraRole
    @State private var open = false

    var body: some View {
        let mask = settings.mask(role)
        Button { open.toggle() } label: {
            Text(mask.label)
                .fontWeight(mask.isOn ? .bold : .regular)
                .frame(minWidth: 36)
                .foregroundStyle(mask.isOn ? Color.black : Color.primary)
        }
        .buttonStyle(.bordered)
        .background(mask.isOn ? RoundedRectangle(cornerRadius: 5).fill(Color.yellow) : nil)
        .help("Mask – black bars showing a 1.85, 2:1, 2.35 or custom frame, with adjustable opacity. Only on the screen, not in the recorded file.")
        .accessibilityLabel("Mask")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            FrameMaskSettings(mask: Binding(get: { settings.mask(role) }, set: { settings.setMask($0, for: role) }),
                              title: "Mask – Camera \(settings.cameraNames.name(role))")
        }
    }
}

/// Ratio, custom ratio and opacity of one mask.
struct FrameMaskSettings: View {
    @Binding var mask: FrameMask
    var title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Picker("", selection: $mask.ratio) {
                ForEach(FrameMask.Ratio.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if mask.ratio == .custom {
                HStack(spacing: 8) {
                    Text("Ratio").foregroundStyle(.secondary)
                    TextField("2.39", value: customBinding, format: .number.precision(.fractionLength(2)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 64)
                        .multilineTextAlignment(.trailing)
                    Text(": 1").foregroundStyle(.secondary)
                    Stepper("", value: customBinding, in: FrameMask.customRange, step: 0.01).labelsHidden()
                    Spacer(minLength: 8)
                    ForEach([1.33, 1.66, 2.39], id: \.self) { value in
                        Button(String(format: "%.2f", value)) { mask.customRatio = value }
                            .controlSize(.small)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Opacity").foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int((mask.opacity * 100).rounded())) %").monospacedDigit()
                }
                Slider(value: $mask.opacity, in: 0...1)
                HStack {
                    ForEach([0.25, 0.5, 0.75, 1.0], id: \.self) { value in
                        Button("\(Int(value * 100)) %") { mask.opacity = value }
                            .controlSize(.small)
                    }
                }
            }
            .disabled(!mask.isOn)

            Text("Only on the screen – the recorded file, the monitor and the phones keep the full picture.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 360)
    }

    private var customBinding: Binding<Double> {
        Binding(get: { mask.customRatio },
                set: { mask.customRatio = min(max($0, FrameMask.customRange.lowerBound), FrameMask.customRange.upperBound) })
    }
}
