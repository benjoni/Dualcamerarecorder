//
//  PictureAdjuster.swift
//  DualCamRecorder
//
//  Picture adjustments set on the Record tab that become part of the recording: anamorphic de-squeeze and the
//  aspect ratio mask (crop). Applied to every frame of an input before the screen, the monitor, the phones and the
//  file – Playback and Edit then show the clip exactly as recorded, nothing to set there.
//
//  The frame keeps its size and pixel format (e.g. 1920×1080, 2vuy or v210):
//  • de-squeeze: the picture is scaled to the full width and 1/squeeze of the height (2× → 1920×540) and placed
//    in the middle with black bars above and below – like a monitor with de-squeeze shows it;
//  • mask: black bars over the de-squeezed picture down to the chosen ratio (1.85, 2:1, 2.35, custom).
//  Used on the input's capture thread only.
//

import Foundation
import CoreVideo
import VideoToolbox

final class PictureAdjuster {
    struct Settings: Equatable {
        /// Anamorphic squeeze of the lens (1 = none).
        var squeeze = 1.0
        /// Width ÷ height of the mask (nil = no mask).
        var maskAspect: Double?

        var isNeutral: Bool { squeeze <= 1.01 && maskAspect == nil }
    }

    private var session: VTPixelTransferSession?
    private var pools: [String: CVPixelBufferPool] = [:]

    init() {
        VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session)
    }

    /// The adjusted frame (a new buffer), or the frame itself when nothing is set or the format is not supported.
    func process(_ source: CVPixelBuffer, settings: Settings) -> CVPixelBuffer {
        guard !settings.isNeutral, let session else { return source }
        let format = CVPixelBufferGetPixelFormatType(source)
        guard Self.supported.contains(format) else { return source }
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        guard let output = buffer(width: width, height: height, format: format) else { return source }

        // Rectangle of the picture inside the frame (rows / columns).
        var top = 0, pictureHeight = height
        if settings.squeeze > 1.01 {
            pictureHeight = min(height, max(2, Int((Double(height) / settings.squeeze / 2).rounded()) * 2))
            top = ((height - pictureHeight) / 2) & ~1
            guard let squeezed = buffer(width: width, height: pictureHeight, format: format),
                  VTPixelTransferSessionTransferImage(session, from: source, to: squeezed) == noErr else { return source }
            fill(output, rows: 0..<height, format: format)
            copyRows(from: squeezed, to: output, at: top)
        } else {
            guard VTPixelTransferSessionTransferImage(session, from: source, to: output) == noErr else { return source }
        }

        // Mask: bars inside the picture rectangle.
        if let aspect = settings.maskAspect, pictureHeight > 0 {
            let pictureAspect = Double(width) / Double(pictureHeight)
            if aspect > pictureAspect + 0.005 {
                // Wider frame → bars above and below.
                let keep = min(pictureHeight, Int((Double(width) / aspect / 2).rounded()) * 2)
                let bar = (pictureHeight - keep) / 2
                fill(output, rows: top..<(top + bar), format: format)
                fill(output, rows: (top + bar + keep)..<(top + pictureHeight), format: format)
            } else if aspect < pictureAspect - 0.005 {
                // Narrower frame → bars left and right.
                let keep = min(width, Int((Double(pictureHeight) * aspect).rounded()))
                let bar = (width - keep) / 2
                fill(output, rows: top..<(top + pictureHeight), columns: 0..<bar, format: format)
                fill(output, rows: top..<(top + pictureHeight), columns: (bar + keep)..<width, format: format)
            }
        }
        CVBufferPropagateAttachments(source, output)
        return output
    }

    // MARK: - Buffers

    private static let supported: Set<OSType> = [kCVPixelFormatType_422YpCbCr8, kCVPixelFormatType_422YpCbCr10,
                                                 kCVPixelFormatType_32BGRA]

    private func buffer(width: Int, height: Int, format: OSType) -> CVPixelBuffer? {
        let key = "\(width)x\(height)/\(format)"
        if pools[key] == nil {
            let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: format,
                                             kCVPixelBufferWidthKey as String: width,
                                             kCVPixelBufferHeightKey as String: height,
                                             kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 6] as CFDictionary,
                                    attributes as CFDictionary, &pool)
            if pools.count > 8 { pools.removeAll() }   // input format changed several times
            pools[key] = pool
        }
        guard let pool = pools[key] else { return nil }
        var out: CVPixelBuffer?
        return CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess ? out : nil
    }

    /// Copies all rows of `source` (same width and format) into `destination` starting at row `top`.
    private func copyRows(from source: CVPixelBuffer, to destination: CVPixelBuffer, at top: Int) {
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        guard let src = CVPixelBufferGetBaseAddress(source), let dst = CVPixelBufferGetBaseAddress(destination) else { return }
        let srcRow = CVPixelBufferGetBytesPerRow(source), dstRow = CVPixelBufferGetBytesPerRow(destination)
        let rows = min(CVPixelBufferGetHeight(source), CVPixelBufferGetHeight(destination) - top)
        let bytes = min(srcRow, dstRow)
        for y in 0..<max(0, rows) {
            memcpy(dst + (top + y) * dstRow, src + y * srcRow, bytes)
        }
    }

    // MARK: - Black

    /// Black in each format, as the repeating byte pattern of one pixel group (2vuy: 2 pixels, v210: 6 pixels,
    /// BGRA: 1 pixel) and the number of pixels in that group.
    private static func black(_ format: OSType) -> (pattern: [UInt8], pixels: Int) {
        switch format {
        case kCVPixelFormatType_422YpCbCr8:
            return ([0x80, 0x10, 0x80, 0x10], 2)                       // Cb Y Cr Y
        case kCVPixelFormatType_422YpCbCr10:
            // v210: four little-endian words of three 10-bit samples – Y 64, Cb / Cr 512.
            func word(_ a: UInt32, _ b: UInt32, _ c: UInt32) -> [UInt8] {
                let w = a | (b << 10) | (c << 20)
                return [UInt8(w & 0xFF), UInt8((w >> 8) & 0xFF), UInt8((w >> 16) & 0xFF), UInt8((w >> 24) & 0xFF)]
            }
            return (word(512, 64, 512) + word(64, 512, 64) + word(512, 64, 512) + word(64, 512, 64), 6)
        default:
            return ([0, 0, 0, 255], 1)                                 // BGRA
        }
    }

    /// Paints `rows` (all columns, or `columns`) black. Columns are widened to whole pixel groups.
    private func fill(_ buffer: CVPixelBuffer, rows: Range<Int>, columns: Range<Int>? = nil, format: OSType) {
        guard !rows.isEmpty else { return }
        let (pattern, groupPixels) = Self.black(format)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let width = CVPixelBufferGetWidth(buffer)
        let groups = (width + groupPixels - 1) / groupPixels
        let firstGroup = columns.map { $0.lowerBound / groupPixels } ?? 0
        let endGroup = columns.map { min(groups, ($0.upperBound + groupPixels - 1) / groupPixels) } ?? groups
        guard endGroup > firstGroup else { return }
        let start = firstGroup * pattern.count
        let length = min((endGroup - firstGroup) * pattern.count, rowBytes - start)
        guard length > 0 else { return }
        // One row of black, then copied into every row.
        var line = [UInt8](repeating: 0, count: length)
        for i in 0..<length { line[i] = pattern[i % pattern.count] }
        let height = CVPixelBufferGetHeight(buffer)
        line.withUnsafeBytes { raw in
            for y in rows where y >= 0 && y < height {
                memcpy(base + y * rowBytes + start, raw.baseAddress!, length)
            }
        }
    }
}
