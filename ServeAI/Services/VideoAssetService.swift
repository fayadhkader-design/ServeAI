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

protocol VideoClipExporting: Sendable {
    func prepare(_ selection: VideoClipSelection) async throws -> URL
}

struct AVVideoClipExporter: VideoClipExporting {
    func prepare(_ selection: VideoClipSelection) async throws -> URL {
        let asset = AVURLAsset(url: selection.sourceURL)
        guard (try? await asset.load(.isReadable)) == true else {
            throw ServeAIError.corruptedVideo
        }

        let duration = try await asset.load(.duration).seconds
        let range = try selection.validated(sourceDuration: duration)
        guard !selection.usesFullClip else { return selection.sourceURL }

        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw ServeAIError.unsupportedVideo
        }

        let supportedTypes = exportSession.supportedFileTypes
        let fileType: AVFileType
        let fileExtension: String
        if supportedTypes.contains(.mp4) {
            fileType = .mp4
            fileExtension = "mp4"
        } else if supportedTypes.contains(.mov) {
            fileType = .mov
            fileExtension = "mov"
        } else {
            throw ServeAIError.unsupportedVideo
        }

        let outputURL = try VideoStorage.makeDestination(extension: fileExtension)
        exportSession.outputURL = outputURL
        exportSession.outputFileType = fileType
        exportSession.shouldOptimizeForNetworkUse = false
        exportSession.timeRange = CMTimeRange(
            start: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
            duration: CMTime(seconds: range.upperBound - range.lowerBound, preferredTimescale: 600)
        )

        do {
            try await export(exportSession)
            return outputURL
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            if error is CancellationError { throw error }
            throw ServeAIError.recordingFailed("The selected clip could not be prepared. \(error.localizedDescription)")
        }
    }

    private func export(_ session: AVAssetExportSession) async throws {
        let box = ExportSessionBox(session)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                box.session.exportAsynchronously {
                    switch box.session.status {
                    case .completed:
                        continuation.resume()
                    case .cancelled:
                        continuation.resume(throwing: CancellationError())
                    case .failed:
                        continuation.resume(throwing: box.session.error ?? ServeAIError.corruptedVideo)
                    default:
                        continuation.resume(throwing: box.session.error ?? ServeAIError.corruptedVideo)
                    }
                }
            }
        } onCancel: {
            box.session.cancelExport()
        }
    }
}

private final class ExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession

    init(_ session: AVAssetExportSession) {
        self.session = session
    }
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
