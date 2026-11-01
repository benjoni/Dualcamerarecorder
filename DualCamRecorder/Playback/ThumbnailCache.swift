//
//  ThumbnailCache.swift
//  DualCamRecorder
//
//  Poster frame from the middle of a take (CamA, or CamB if A is missing), generated
//  asynchronously with AVAssetImageGenerator at small size and cached in memory.
//

import AppKit
import AVFoundation
import SwiftUI

final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 300
        return c
    }()

    func cached(url: URL, modified: Date) -> NSImage? {
        cache.object(forKey: key(url, modified))
    }

    func image(url: URL, modified: Date) async -> NSImage? {
        let k = key(url, modified)
        if let hit = cache.object(forKey: k) { return hit }

        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.isValid, duration.seconds > 0 else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 180)
        // ProRes is intra-frame, any nearby frame is cheap – allow some tolerance.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        let middle = CMTimeMultiplyByRatio(duration, multiplier: 1, divisor: 2)
        guard let result = try? await generator.image(at: middle) else { return nil }
        let cgImage = result.image
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        cache.setObject(image, forKey: k)
        return image
    }

    /// Frame at a given time (timeline pieces show the middle of their IN → OUT).
    func image(url: URL, at seconds: Double) async -> NSImage? {
        let k = "\(url.path)|@\(Int(seconds * 10))" as NSString
        if let hit = cache.object(forKey: k) { return hit }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 180)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)
        guard let result = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)) else { return nil }
        let image = NSImage(cgImage: result.image, size: NSSize(width: result.image.width, height: result.image.height))
        cache.setObject(image, forKey: k)
        return image
    }

    private func key(_ url: URL, _ modified: Date) -> NSString {
        "\(url.path)|\(modified.timeIntervalSince1970)" as NSString
    }
}

/// Small 16:9 poster frame for the take list.
struct TakeThumbnail: View {
    let take: Take
    @State private var image: NSImage?

    private var source: URL? { take.camA ?? take.camB }

    var body: some View {
        ZStack {
            Rectangle().fill(Color.black)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "film")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 96, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: "\(source?.path ?? "")|\(take.modified.timeIntervalSince1970)") {
            guard let source else { image = nil; return }
            if let hit = ThumbnailCache.shared.cached(url: source, modified: take.modified) {
                image = hit
                return
            }
            image = nil
            image = await ThumbnailCache.shared.image(url: source, modified: take.modified)
        }
    }
}
