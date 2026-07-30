import CoreGraphics
import XCTest
@testable import ServeAI

final class StadiumVideoQualityTests: XCTestCase {
    func testTransientCompetingPoseDoesNotBlockOtherwiseUsableClip() async throws {
        let assessor = VisionRecordingQualityAssessor(
            frameExtractor: StadiumFrameExtractor(frameCount: 12),
            poseDetector: StadiumPoseDetector(ambiguousFrames: [4])
        )

        let report = try await assessor.assess(
            videoURL: URL(fileURLWithPath: "/tmp/stadium-serve.mov"),
            cameraAngle: .rear
        )

        XCTAssertTrue(report.isAcceptable)
        XCTAssertFalse(report.issues.contains { $0.kind == .multiplePeople })
        XCTAssertEqual(report.poseFrameCount, 11)
    }

    func testSustainedComparableForegroundPlayersRemainBlocking() async throws {
        let assessor = VisionRecordingQualityAssessor(
            frameExtractor: StadiumFrameExtractor(frameCount: 12),
            poseDetector: StadiumPoseDetector(ambiguousFrames: [1, 2, 3, 4])
        )

        let report = try await assessor.assess(
            videoURL: URL(fileURLWithPath: "/tmp/two-players.mov"),
            cameraAngle: .rear
        )

        XCTAssertEqual(report.status, .rejected)
        let issue = try XCTUnwrap(
            report.issues.first { $0.kind == .multiplePeople }
        )
        XCTAssertEqual(issue.severity, .blocking)
        XCTAssertTrue(issue.detail.contains("4 of 12"))
    }
}

private struct StadiumFrameExtractor: VideoFrameExtracting {
    let frameCount: Int

    func extractFrames(
        from _: URL,
        samplesPerSecond _: Double,
        maximumFrames _: Int
    ) async throws -> ExtractedVideo {
        let image = try onePixelImage()
        let frames = (0..<frameCount).map {
            VideoFrame(image: image, timestamp: Double($0))
        }
        return ExtractedVideo(
            frames: frames,
            metadata: VideoMetadata(
                duration: 6,
                width: 1080,
                height: 1920,
                nominalFrameRate: 60,
                usableFrames: 0,
                sampledFrames: frameCount
            )
        )
    }
}

private struct StadiumPoseDetector: PoseDetectionService {
    let ambiguousFrames: Set<Int>

    func detectPose(
        in _: CGImage,
        at timestamp: TimeInterval
    ) async throws -> PoseFrame? {
        if ambiguousFrames.contains(Int(timestamp)) {
            throw ServeAIError.multiplePeopleDetected
        }
        let joints = Dictionary(
            uniqueKeysWithValues: BodyJoint.allCases.enumerated().map { index, joint in
                (
                    joint,
                    PosePoint(
                        x: 0.32 + Double(index % 4) * 0.08,
                        y: 0.18 + Double(index / 4) * 0.18,
                        confidence: 0.92
                    )
                )
            }
        )
        return PoseFrame(
            timestamp: timestamp,
            joints: joints,
            bodyConfidence: 0.92
        )
    }
}

private func onePixelImage() throws -> CGImage {
    let data = Data([0, 0, 0, 255]) as CFData
    guard let provider = CGDataProvider(data: data),
          let image = CGImage(
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.last.rawValue
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
          ) else {
        throw ServeAIError.corruptedVideo
    }
    return image
}
