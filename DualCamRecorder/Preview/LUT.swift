//
//  LUT.swift
//  DualCamRecorder
//
//  LUTs (.cube): the library of imported LUTs and the colour cube. PictureAdjuster burns the chosen LUT into
//  each input's pictures – Record screen, waveform, Blackmagic monitor, phones and the recorded file.
//

import Foundation
import Combine
import AppKit
import CoreImage
import CoreVideo
import os

/// A colour cube read from a .cube file (Resolve / Adobe format). 1D tables are turned into a 33-point cube.
final class CubeLUT: @unchecked Sendable {
    /// File name in the library ("LogC3 to Rec709.cube").
    let name: String
    let size: Int
    /// RGBA float32, red changing fastest – the layout of Core Image's colour cube.
    let data: Data
    /// Input range of the table (DOMAIN_MIN / DOMAIN_MAX); [0, 1] in almost every LUT.
    let domainMin: SIMD3<Float>
    let domainMax: SIMD3<Float>

    static let maxSize = 128

    enum ParseError: LocalizedError {
        case notText
        case noSize
        case badSize(Int)
        case wrongCount(expected: Int, found: Int)
        case badLine(Int)

        var errorDescription: String? {
            switch self {
            case .notText: return "not a text file"
            case .noSize: return "no LUT_3D_SIZE or LUT_1D_SIZE line"
            case .badSize(let n): return "size \(n) is not supported (2 … \(CubeLUT.maxSize))"
            case .wrongCount(let expected, let found): return "\(found) colour lines instead of \(expected)"
            case .badLine(let n): return "line \(n) cannot be read"
            }
        }
    }

    convenience init(url: URL) throws {
        let bytes = try Data(contentsOf: url)
        guard let text = String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .isoLatin1),
              !bytes.contains(0) else { throw ParseError.notText }
        try self.init(name: url.lastPathComponent, text: text)
    }

    init(name: String, text: String) throws {
        self.name = name
        var size3 = 0, size1 = 0
        var lo = SIMD3<Float>(0, 0, 0), hi = SIMD3<Float>(1, 1, 1)
        var values: [Float] = []
        values.reserveCapacity(3 * 33 * 33 * 33)

        var lineNumber = 0
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
            lineNumber += 1
            let parts = raw.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let first = parts.first, !first.hasPrefix("#") else { continue }
            if let r = Float(first) {
                guard parts.count >= 3, let g = Float(parts[1]), let b = Float(parts[2]) else {
                    throw ParseError.badLine(lineNumber)
                }
                values.append(r); values.append(g); values.append(b)
                continue
            }
            func floats(_ count: Int) -> [Float]? {
                let f = parts.dropFirst().prefix(count).compactMap { Float($0) }
                return f.count == count ? f : nil
            }
            switch first.uppercased() {
            case "LUT_3D_SIZE": size3 = parts.count > 1 ? Int(parts[1]) ?? -1 : -1
            case "LUT_1D_SIZE": size1 = parts.count > 1 ? Int(parts[1]) ?? -1 : -1
            case "DOMAIN_MIN": if let f = floats(3) { lo = SIMD3(f[0], f[1], f[2]) }
            case "DOMAIN_MAX": if let f = floats(3) { hi = SIMD3(f[0], f[1], f[2]) }
            case "LUT_3D_INPUT_RANGE", "LUT_1D_INPUT_RANGE":
                if let f = floats(2) { lo = SIMD3(repeating: f[0]); hi = SIMD3(repeating: f[1]) }
            default: continue   // TITLE and other keywords
            }
        }

        if size3 != 0 {
            guard (2...Self.maxSize).contains(size3) else { throw ParseError.badSize(size3) }
            let expected = size3 * size3 * size3
            guard values.count / 3 == expected else { throw ParseError.wrongCount(expected: expected, found: values.count / 3) }
            var rgba = [Float](repeating: 1, count: expected * 4)
            for i in 0..<expected {
                rgba[i * 4] = values[i * 3]
                rgba[i * 4 + 1] = values[i * 3 + 1]
                rgba[i * 4 + 2] = values[i * 3 + 2]
            }
            size = size3
            data = rgba.withUnsafeBufferPointer { Data(buffer: $0) }
        } else if size1 != 0 {
            guard (2...65536).contains(size1) else { throw ParseError.badSize(size1) }
            guard values.count / 3 == size1 else { throw ParseError.wrongCount(expected: size1, found: values.count / 3) }
            // Per-channel curves → cube (each output channel depends on its own input only).
            let n = 33
            func curve(_ channel: Int, _ x: Float) -> Float {
                let p = x * Float(size1 - 1)
                let i = min(Int(p), size1 - 2)
                let t = p - Float(i)
                return values[i * 3 + channel] * (1 - t) + values[(i + 1) * 3 + channel] * t
            }
            var rgba = [Float](repeating: 1, count: n * n * n * 4)
            for b in 0..<n {
                for g in 0..<n {
                    for r in 0..<n {
                        let i = ((b * n + g) * n + r) * 4
                        rgba[i] = curve(0, Float(r) / Float(n - 1))
                        rgba[i + 1] = curve(1, Float(g) / Float(n - 1))
                        rgba[i + 2] = curve(2, Float(b) / Float(n - 1))
                    }
                }
            }
            size = n
            data = rgba.withUnsafeBufferPointer { Data(buffer: $0) }
        } else {
            throw ParseError.noSize
        }
        guard hi.x > lo.x, hi.y > lo.y, hi.z > lo.z else { throw ParseError.badLine(0) }
        domainMin = lo
        domainMax = hi
    }

    private var hasDefaultDomain: Bool { domainMin == SIMD3(0, 0, 0) && domainMax == SIMD3(1, 1, 1) }

    /// The picture with the LUT applied to its values as they are (no colour management) –
    /// for pictures rendered with `LUTRender.context`.
    func apply(to image: CIImage) -> CIImage {
        let filter = CIFilter(name: "CIColorCube")!
        filter.setValue(size, forKey: "inputCubeDimension")
        filter.setValue(data, forKey: "inputCubeData")
        filter.setValue(domainScaled(image), forKey: kCIInputImageKey)
        return filter.outputImage ?? image
    }

    /// Input range other than [0, 1]: values scaled into the cube first.
    private func domainScaled(_ image: CIImage) -> CIImage {
        guard !hasDefaultDomain else { return image }
        let scale = 1 / (domainMax - domainMin)
        let bias = -domainMin * scale
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(scale.x), y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: CGFloat(scale.y), z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(scale.z), w: 0),
            "inputBiasVector": CIVector(x: CGFloat(bias.x), y: CGFloat(bias.y), z: CGFloat(bias.z), w: 0),
        ])
    }
}

/// Renders a picture through a LUT into a new BGRA buffer of the same size (GPU).
/// Each user keeps its own `LUTRender` (not thread-safe: one queue per instance).
final class LUTRender {
    /// No colour management: the LUT works on the picture's values as they are.
    static let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(),
                                             .cacheIntermediates: false, .name: "LUT"])
    private var pool: CVPixelBufferPool?
    private var poolSize = (0, 0)

    /// `source` in any format VideoToolbox / Core Image read as RGB (BGRA here); nil if it cannot be rendered.
    func apply(_ lut: CubeLUT, to source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        if pool == nil || poolSize != (width, height) {
            let attrs: [String: Any] = [
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &p)
            pool = p
            poolSize = (width, height)
        }
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out) == kCVReturnSuccess, let out else { return nil }
        let image = CIImage(cvPixelBuffer: source, options: [.colorSpace: NSNull()])
        Self.context.render(lut.apply(to: image), to: out, bounds: image.extent, colorSpace: nil)
        CVBufferPropagateAttachments(source, out)
        return out
    }
}

/// Imported LUTs: copies of the .cube files in Application Support/DualCamRecorder/LUTs,
/// picked per camera in the LUT button above each picture.
final class LUTLibrary: ObservableObject {
    static let shared = LUTLibrary()

    /// File names, sorted ("LogC3 to Rec709.cube" …).
    @Published private(set) var names: [String] = []
    /// Goes up when files are imported or removed (a LUT may have been replaced under the same name).
    @Published private(set) var revision = 0

    let folder: URL
    private var cache: [String: CubeLUT] = [:]   // main queue
    private let loadQueue = DispatchQueue(label: "lut-load", qos: .userInitiated)

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        folder = support.appendingPathComponent("DualCamRecorder/LUTs", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        refresh()
    }

    func refresh() {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        names = files.map(\.lastPathComponent)
            .filter { $0.lowercased().hasSuffix(".cube") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// "LogC3 to Rec709" (file name without .cube).
    static func title(_ name: String) -> String {
        name.lowercased().hasSuffix(".cube") ? String(name.dropLast(5)) : name
    }

    struct ImportResult {
        var imported: [String] = []
        /// File name + why it was not imported.
        var failed: [(String, String)] = []
    }

    /// Checks and copies the files (a LUT of the same name is replaced). Completion on the main queue.
    func importFiles(_ urls: [URL], completion: @escaping (ImportResult) -> Void) {
        let folder = self.folder
        loadQueue.async {
            var result = ImportResult()
            var loaded: [CubeLUT] = []
            for url in urls {
                let name = url.lastPathComponent
                guard name.lowercased().hasSuffix(".cube") else {
                    result.failed.append((name, "not a .cube file")); continue
                }
                do {
                    let lut = try CubeLUT(url: url)
                    let target = folder.appendingPathComponent(name)
                    if target.standardizedFileURL != url.standardizedFileURL {
                        try? FileManager.default.removeItem(at: target)
                        try FileManager.default.copyItem(at: url, to: target)
                    }
                    loaded.append(lut)
                    result.imported.append(name)
                } catch {
                    result.failed.append((name, error.localizedDescription))
                }
            }
            DispatchQueue.main.async {
                for lut in loaded { self.cache[lut.name] = lut }
                self.refresh()
                self.revision += 1
                completion(result)
            }
        }
    }

    /// Moves the file to the Trash (projects using it show the picture without a LUT).
    func remove(_ name: String) {
        let url = folder.appendingPathComponent(name)
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        cache[name] = nil
        refresh()
        revision += 1
    }

    /// The LUT of that name (nil = none / missing / unreadable). Completion on the main queue.
    func load(_ name: String, completion: @escaping (CubeLUT?) -> Void) {
        guard !name.isEmpty, names.contains(name) else { completion(nil); return }
        if let cached = cache[name] { completion(cached); return }
        let url = folder.appendingPathComponent(name)
        loadQueue.async {
            let lut = try? CubeLUT(url: url)
            DispatchQueue.main.async {
                if let lut { self.cache[name] = lut }
                completion(lut)
            }
        }
    }
}
