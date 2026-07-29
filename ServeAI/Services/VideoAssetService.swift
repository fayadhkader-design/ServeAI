import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

protocol VideoAssetManaging: Sendable {
    func thumbnailData(for videoURL: URL) async -> Data?
    @discardableResult func deleteOwnedVideo(at videoURL: URL) throws -> Bool
    @discardableResult func cleanupOrphanedVideos(referencedURLs: [URL]) throws -> Int
}

struct LocalVideoAssetManager: VideoAssetManaging {
    func thumbnailData(for videoURL: URL) async -> Data? {
        let asset = AVURLAsset(url: videoURL)
        guard (try? await asset.load(.isReadable)) == true,
              let duration = try? await asset.load(.duration),
              duration.seconds.isFinite else {
            return nil
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.15, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.15, preferredTimescale: 600)
        let previewTime = min(max(duration.seconds * 0.20, 0), 1)

        guard let result = try? await generator.image(
            at: CMTime(seconds: previewTime, preferredTimescale: 600)
        ) else {
            return nil
        }
        return jpegData(for: result.image)
    }

    @discardableResult
    func deleteOwnedVideo(at videoURL: URL) throws -> Bool {
        guard isAppOwned(videoURL) else { return false }
        guard FileManager.default.fileExists(atPath: videoURL.path) else { return true }
        try FileManager.default.removeItem(at: videoURL)
        return true
    }

    @discardableResult
    func cleanupOrphanedVideos(referencedURLs: [URL]) throws -> Int {
        let directory = VideoStorage.directoryURL
        guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }

        let references = Set(referencedURLs.filter(isAppOwned).map(canonicalPath))
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var removed = 0
        for file in files {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true, !references.contains(canonicalPath(file)) else { continue }
            try FileManager.default.removeItem(at: file)
            removed += 1
        }
        return removed
    }

    private func isAppOwned(_ url: URL) -> Bool {
        canonicalPath(url.deletingLastPathComponent()) == canonicalPath(VideoStorage.directoryURL)
    }

    private func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func jpegData(for image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.74] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
