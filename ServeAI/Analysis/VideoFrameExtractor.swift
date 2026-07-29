import AVFoundation
import CoreGraphics
import Foundation

struct VideoFrame: @unchecked Sendable {
    let image: CGImage
    let timestamp: TimeInterval
}

struct ExtractedVideo: @unchecked Sendable {
    let frames: [VideoFrame]
    let metadata: VideoMetadata
}

protocol VideoFrameExtracting: Sendable {
    func extractFrames(from url: URL, samplesPerSecond: Double, maximumFrames: Int) async throws -> ExtractedVideo
}

struct AVVideoFrameExtractor: VideoFrameExtracting {
    func extractFrames(from url: URL, samplesPerSecond: Double = 15, maximumFrames: Int = 180) async throws -> ExtractedVideo {
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isReadable) else { throw ServeAIError.corruptedVideo }
        let duration = try await asset.load(.duration).seconds
        guard duration >= 2 else { throw ServeAIError.videoTooShort }
        guard duration <= 45 else { throw ServeAIError.videoTooLong }

        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw ServeAIError.unsupportedVideo }
        let size = try await track.load(.naturalSize)
        let frameRate = try await track.load(.nominalFrameRate)
        let count = min(maximumFrames, max(2, Int(duration * samplesPerSecond)))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 120)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 120)

        var frames: [VideoFrame] = []
        frames.reserveCapacity(count)
        for index in 0..<count {
            try Task.checkCancellation()
            let seconds = duration * Double(index) / Double(max(1, count - 1))
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            if let result = try? await generator.image(at: time) {
                frames.append(VideoFrame(image: result.image, timestamp: result.actualTime.seconds))
            }
        }
        guard !frames.isEmpty else { throw ServeAIError.corruptedVideo }
        return ExtractedVideo(
            frames: frames,
            metadata: VideoMetadata(duration: duration, width: Int(abs(size.width)), height: Int(abs(size.height)), nominalFrameRate: Double(frameRate), usableFrames: 0, sampledFrames: frames.count)
        )
    }
}
