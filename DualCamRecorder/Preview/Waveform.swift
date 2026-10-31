//
//  Waveform.swift
//  DualCamRecorder
//
//  Luma waveform monitor (0–100 IRE) computed from a BGRA picture.
//  X = picture column, Y = luma level, brightness = how many pixels have that level.
//  The BGRA buffers come from VideoToolbox / AVFoundation conversions of video-range
//  Rec.709 YUV, so RGB 0…255 corresponds to 0…100 IRE (super-whites/blacks are clipped).
//

import SwiftUI
import CoreVideo
import CoreGraphics

/// Latest waveform image for one camera. Updated on the main queue.
final class WaveformModel: ObservableObject {
    @Published var image: CGImage?
}

enum WaveformRenderer {
    static let columns = 256
    static let levels = 128

    /// Builds the waveform image from a 32BGRA pixel buffer (any size). Runs off the main thread.
    static func image(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard w > 0, h > 0 else { return nil }

        // Sample about 2 pixels per output column and ~135 rows – plenty for a monitor.
        let stepX = max(1, w / (columns * 2))
        let stepY = max(1, h / 135)
        var counts = [UInt32](repeating: 0, count: columns * levels)
        let pixels = base.assumingMemoryBound(to: UInt8.self)

        var y = 0
        var samplesPerColumn = 0
        while y < h {
            let row = pixels + y * bytesPerRow
            var x = 0
            while x < w {
                let p = row + x * 4
                let b = Int(p[0]), g = Int(p[1]), r = Int(p[2])
                // Rec.709 luma weights (0.2126, 0.7152, 0.0722) in 8.8 fixed point.
                let luma = (54 * r + 183 * g + 19 * b) >> 8
                let column = x * columns / w
                let level = (levels - 1) - min(levels - 1, luma * (levels - 1) / 255)
                counts[level * columns + column] &+= 1
                x += stepX
            }
            y += stepY
            samplesPerColumn += max(1, (w / stepX) / columns)
        }

        // Brightness: square-root curve so thin traces stay visible.
        let reference = Double(max(1, samplesPerColumn)) * 0.06
        var rgba = [UInt8](repeating: 0, count: columns * levels * 4)
        for i in 0..<(columns * levels) where counts[i] > 0 {
            let intensity = min(1.0, (Double(counts[i]) / reference).squareRoot())
            let a = UInt8(max(40, intensity * 255))
            // Premultiplied green-white trace.
            rgba[i * 4 + 0] = UInt8(Double(a) * 0.55)
            rgba[i * 4 + 1] = a
            rgba[i * 4 + 2] = UInt8(Double(a) * 0.55)
            rgba[i * 4 + 3] = a
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: columns, height: levels, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: columns * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// Small waveform panel with an IRE graticule in the bottom-right corner of a picture.
struct WaveformOverlay: View {
    @ObservedObject var model: WaveformModel

    var body: some View {
        GeometryReader { geo in
            // Small monitor in the bottom-right corner of the picture.
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.65))
                if let image = model.image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .padding(.leading, 22)
                }
                graticule
            }
            .frame(width: max(140, geo.size.width * 0.3), height: max(70, geo.size.height * 0.28))
            .padding(8)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottomTrailing)
        }
        .allowsHitTesting(false)
    }

    /// 100 / 50 / 0 IRE lines with labels.
    private var graticule: some View {
        GeometryReader { g in
            ForEach([100, 50, 0], id: \.self) { ire in
                let y = g.size.height * CGFloat(100 - ire) / 100
                Path { path in
                    path.move(to: CGPoint(x: 22, y: y))
                    path.addLine(to: CGPoint(x: g.size.width, y: y))
                }
                .stroke(Color.white.opacity(ire == 100 || ire == 0 ? 0.45 : 0.2),
                        style: StrokeStyle(lineWidth: 1, dash: ire == 100 || ire == 0 ? [] : [3, 3]))
                Text("\(ire)")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
                    .position(x: 11, y: min(max(y, 6), g.size.height - 6))
            }
        }
    }
}
