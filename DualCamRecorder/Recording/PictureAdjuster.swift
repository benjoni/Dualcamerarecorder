//
//  PictureAdjuster.swift
//  DualCamRecorder
//
//  Picture adjustment set on the Record tab that becomes part of the recording: the aspect ratio mask (crop). Applied to every frame of an input before the screen, the monitor, the phones and the
//  file – Playback and Edit then show the clip exactly as recorded, nothing to set there.
//
//  The frame keeps its size and pixel format (e.g. 1920×1080, 2vuy or v210); the mask is bars over the picture
//  down to the chosen ratio (1.85, 2:1, 2.35, custom) – black at 100 % opacity, below that the picture under the
//  bars is darkened (luma toward black, chroma toward grey) by the opacity.
//  Used on the input's capture thread only.
//

import Foundation
import CoreVideo
import VideoToolbox

final class PictureAdjuster {
    struct Settings: Equatable {
        /// Width ÷ height of the mask (nil = no mask).
        var maskAspect: Double?
        /// How dark the bars are: 1 = black, 0.5 = the picture under them at half brightness.
        var maskOpacity = 1.0

        var isNeutral: Bool { maskAspect == nil || maskOpacity < 0.005 }
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

        guard VTPixelTransferSessionTransferImage(session, from: source, to: output) == noErr else { return source }
        // Rectangle of the picture inside the frame (rows).
        let top = 0, pictureHeight = height

        // Mask: bars inside the picture rectangle.
        if let aspect = settings.maskAspect, pictureHeight > 0 {
            let pictureAspect = Double(width) / Double(pictureHeight)
            if aspect > pictureAspect + 0.005 {
                // Wider frame → bars above and below.
                let keep = min(pictureHeight, Int((Double(width) / aspect / 2).rounded()) * 2)
                let bar = (pictureHeight - keep) / 2
                darken(output, rows: top..<(top + bar), format: format, opacity: settings.maskOpacity)
                darken(output, rows: (top + bar + keep)..<(top + pictureHeight), format: format, opacity: settings.maskOpacity)
            } else if aspect < pictureAspect - 0.005 {
                // Narrower frame → bars left and right.
                let keep = min(width, Int((Double(pictureHeight) * aspect).rounded()))
                let bar = (width - keep) / 2
                darken(output, rows: top..<(top + pictureHeight), columns: 0..<bar, format: format,
                       opacity: settings.maskOpacity)
                darken(output, rows: top..<(top + pictureHeight), columns: (bar + keep)..<width, format: format,
                       opacity: settings.maskOpacity)
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

    /// Byte range of `columns` (or the whole row) in one row, widened to whole pixel groups; nil when empty.
    private static func byteRange(width: Int, rowBytes: Int, columns: Range<Int>?, format: OSType) -> Range<Int>? {
        let (pattern, groupPixels) = black(format)
        let groups = (width + groupPixels - 1) / groupPixels
        let firstGroup = columns.map { $0.lowerBound / groupPixels } ?? 0
        let endGroup = columns.map { min(groups, ($0.upperBound + groupPixels - 1) / groupPixels) } ?? groups
        guard endGroup > firstGroup else { return nil }
        let start = firstGroup * pattern.count
        let length = min((endGroup - firstGroup) * pattern.count, rowBytes - start)
        return length > 0 ? start..<(start + length) : nil
    }

    /// Paints `rows` (all columns, or `columns`) black. Columns are widened to whole pixel groups.
    private func fill(_ buffer: CVPixelBuffer, rows: Range<Int>, columns: Range<Int>? = nil, format: OSType) {
        guard !rows.isEmpty else { return }
        let pattern = Self.black(format).pattern
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard let range = Self.byteRange(width: CVPixelBufferGetWidth(buffer), rowBytes: rowBytes,
                                         columns: columns, format: format) else { return }
        // One row of black, then copied into every row.
        var line = [UInt8](repeating: 0, count: range.count)
        for i in 0..<range.count { line[i] = pattern[i % pattern.count] }
        let height = CVPixelBufferGetHeight(buffer)
        line.withUnsafeBytes { raw in
            for y in rows where y >= 0 && y < height {
                memcpy(base + y * rowBytes + range.lowerBound, raw.baseAddress!, range.count)
            }
        }
    }

    // MARK: - Darken (opacity below 100 %)

    /// Darkens `rows` (all columns, or `columns`) by `opacity`: 1 = black (as `fill`), 0.5 = half brightness.
    /// Luma goes toward black, chroma toward grey, so the bars stay neutral like a black overlay.
    private func darken(_ buffer: CVPixelBuffer, rows: Range<Int>, columns: Range<Int>? = nil, format: OSType,
                        opacity: Double) {
        if opacity >= 0.995 { fill(buffer, rows: rows, columns: columns, format: format); return }
        guard !rows.isEmpty, opacity > 0.005 else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard let range = Self.byteRange(width: CVPixelBufferGetWidth(buffer), rowBytes: rowBytes,
                                         columns: columns, format: format) else { return }
        let keep = 1 - opacity
        let height = CVPixelBufferGetHeight(buffer)
        let validRows = max(0, rows.lowerBound)..<min(height, rows.upperBound)

        switch format {
        case kCVPixelFormatType_422YpCbCr8:
            // 2vuy: Cb Y Cr Y – even bytes chroma (toward 128), odd bytes luma (toward 16).
            let luma = Self.table(count: 256, black: 16, keep: keep), chroma = Self.table(count: 256, black: 128, keep: keep)
            for y in validRows {
                let row = (base + y * rowBytes + range.lowerBound).assumingMemoryBound(to: UInt8.self)
                var i = 0
                while i + 1 < range.count {
                    row[i] = UInt8(chroma[Int(row[i])])
                    row[i + 1] = UInt8(luma[Int(row[i + 1])])
                    i += 2
                }
            }
        case kCVPixelFormatType_422YpCbCr10:
            // v210: words of three 10-bit samples in the order Cb Y Cr Y Cb Y Cr Y Cb Y Cr Y – odd samples luma
            // (toward 64), even samples chroma (toward 512).
            let luma = Self.table(count: 1024, black: 64, keep: keep), chroma = Self.table(count: 1024, black: 512, keep: keep)
            let words = range.count / 4
            for y in validRows {
                let row = (base + y * rowBytes + range.lowerBound).assumingMemoryBound(to: UInt32.self)
                for w in 0..<words {
                    let value = UInt32(littleEndian: row[w])
                    var out: UInt32 = value & 0xC000_0000
                    for j in 0..<3 {
                        let sample = Int((value >> UInt32(10 * j)) & 0x3FF)
                        let isLuma = (w * 3 + j) % 2 == 1
                        out |= UInt32(isLuma ? luma[sample] : chroma[sample]) << UInt32(10 * j)
                    }
                    row[w] = out.littleEndian
                }
            }
        default:
            // BGRA: colour bytes toward 0, alpha untouched.
            let scale = Self.table(count: 256, black: 0, keep: keep)
            for y in validRows {
                let row = (base + y * rowBytes + range.lowerBound).assumingMemoryBound(to: UInt8.self)
                var i = 0
                while i + 3 < range.count {
                    row[i] = UInt8(scale[Int(row[i])]); row[i + 1] = UInt8(scale[Int(row[i + 1])])
                    row[i + 2] = UInt8(scale[Int(row[i + 2])])
                    i += 4
                }
            }
        }
    }

    /// value → black + (value − black) × keep, for every possible sample value.
    private static func table(count: Int, black: Int, keep: Double) -> [UInt16] {
        (0..<count).map { v in UInt16(max(0, min(count - 1, Int((Double(black) + Double(v - black) * keep).rounded())))) }
    }
}
