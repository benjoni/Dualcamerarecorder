//
//  Watermark.swift
//  DualCamRecorder
//
//  Text burned into the live view pictures sent to crew phones: repeated diagonally over the whole picture,
//  half transparent, so a screenshot or a recording of the phone always carries it (and cropping cannot remove it).
//

import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

enum Watermark {
    static let defaultText = "CONFIDENTIAL"

    /// The JPEG with `text` tiled over it (nil when it cannot be decoded / encoded).
    static func apply(to jpeg: Data, text: String, quality: Double) -> Data? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let width = CGFloat(image.width), height = CGFloat(image.height)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let label = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultText : text
        let fontSize = max(12, height / 13)
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 0.3),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: attributes))
        let bounds = CTLineGetBoundsWithOptions(line, [])

        // Diagonal rows, every other row shifted by half a step, covering the rotated picture completely.
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: fontSize / 8, color: CGColor(gray: 0, alpha: 0.35))
        ctx.translateBy(x: width / 2, y: height / 2)
        ctx.rotate(by: .pi / 8)
        let stepX = bounds.width + fontSize * 2.5
        let stepY = fontSize * 3.2
        let reach = hypot(width, height) / 2 + stepX
        var row = 0
        var y = -reach
        while y < reach {
            var x = -reach + (row % 2 == 0 ? 0 : stepX / 2)
            while x < reach {
                ctx.textPosition = CGPoint(x: x, y: y)
                CTLineDraw(line, ctx)
                x += stepX
            }
            y += stepY
            row += 1
        }
        ctx.restoreGState()

        guard let marked = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, marked,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
