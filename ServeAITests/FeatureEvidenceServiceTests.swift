import CoreGraphics
import XCTest
@testable import ServeAI

final class FeatureEvidenceServiceTests: XCTestCase {
    func testVisionAnalysisPersistsPoseSequenceAndSourceFingerprint() async throws {
        let service = VisionPoseAnalysisService(
            frameExtractor: EvidenceFrameExtractor(),
            poseDetector: EvidencePoseDetector(),
            poseTracker: MovingAveragePoseTrackingService(),
            phaseDetector: EvidencePhaseDetector(),
            metricsCalculator: ServeMetricsCalculator(),
            confidenceCalculator: AnalysisConfidenceCalculator(),
            feedbackGenerator: ServeFeedbackGenerator(),
            videoHasher: EvidenceVideoHasher()
        )

        let analysis = try await service.analyze(
            videoURL: URL(fileURLWithPath: "/tmp/serveai-evidence.mov"),
            cameraAngle: .rear,
            skillLevel: .intermediate,
            progress: { _ in }
        )

        let evidence = try XCTUnwrap(analysis.modelFeatureEvidence)
        XCTAssertTrue(evidence.isCompleteForDataset)
        XCTAssertEqual(evidence.sequence.frames.count, 20)
        XCTAssertEqual(evidence.sequence.cameraAngle, .rear)
        XCTAssertEqual(evidence.provenance.videoSHA256, String(repeating: "a", count: 64))
        XCTAssertEqual(evidence.provenance.poseDetectorIdentifier, "test.pose-detector")
        XCTAssertEqual(evidence.provenance.requestedSamplesPerSecond, 15)
    }

    func testRejectedPilotSampleProducesEvidenceButNoCoaching() async throws {
        let metadata = VideoMetadata(
            duration: 3,
            width: 1920,
            height: 1080,
            nominalFrameRate: 60,
            usableFrames: 18,
            sampledFrames: 20
        )
        let quality = RecordingQualityReport(
            metadata: metadata,
            poseFrameCount: 18,
            poseCoverage: 0.9,
            meanPoseConfidence: 0.92,
            fullBodyCoverage: 0.9,
            edgeClippingRatio: 0.1,
            issues: [
                .init(
                    kind: .multiplePeople,
                    severity: .blocking,
                    title: "More than one person is visible",
                    detail: "Ambiguous frames were found.",
                    recovery: "Record one player for coaching."
                )
            ]
        )
        let service = ResearchCaptureService(
            frameExtractor: EvidenceFrameExtractor(),
            poseDetector: ResearchPoseDetector(),
            poseTracker: MovingAveragePoseTrackingService(),
            videoHasher: EvidenceVideoHasher()
        )
        let slot = try XCTUnwrap(CapturePlanSlot(number: 1))

        let analysis = try await service.makeRejectedSample(
            videoURL: URL(fileURLWithPath: "/tmp/serveai-rejected-sample.mov"),
            slot: slot,
            qualityReport: quality
        )

        XCTAssertEqual(analysis.source, .researchCapture)
        XCTAssertEqual(analysis.overallScore, 0)
        XCTAssertTrue(analysis.phaseScores.isEmpty)
        XCTAssertTrue(analysis.insights.isEmpty)
        XCTAssertTrue(analysis.drills.isEmpty)
        XCTAssertTrue(analysis.modelFeatureEvidence?.isCompleteForDataset == true)
        XCTAssertEqual(analysis.modelFeatureEvidence?.provenance.detectedFrameCount, 18)
        XCTAssertTrue(analysis.limitations.first?.detail.contains("no technique score") == true)
        let assignment = try CapturePlanAssignment.make(
            slotID: slot.slotID,
            participantPseudonym: slot.participantPseudonym
        )
        XCTAssertTrue(assignment.observedMismatches(in: analysis).isEmpty)
    }
}

private struct EvidenceFrameExtractor: VideoFrameExtracting {
    func extractFrames(from _: URL, samplesPerSecond _: Double, maximumFrames _: Int) async throws -> ExtractedVideo {
        let image = try makeImage()
        let frames = (0..<20).map { index in
            VideoFrame(image: image, timestamp: Double(index) * 0.1)
        }
        return ExtractedVideo(
            frames: frames,
            metadata: VideoMetadata(
                duration: 3,
                width: 1920,
                height: 1080,
                nominalFrameRate: 60,
                usableFrames: 20,
                sampledFrames: 20
            )
        )
    }

    private func makeImage() throws -> CGImage {
        let data = Data([0, 0, 0, 255]) as CFData
        guard let provider = CGDataProvider(data: data),
              let image = CGImage(
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw ServeAIError.corruptedVideo
        }
        return image
    }
}

private struct EvidencePoseDetector: PoseDetectionService {
    let provenanceIdentifier = "test.pose-detector"
    let provenanceVersion = "1"

    func detectPose(in _: CGImage, at timestamp: TimeInterval) async throws -> PoseFrame? {
        let joints = Dictionary(uniqueKeysWithValues: BodyJoint.allCases.enumerated().map { index, joint in
            (
                joint,
                PosePoint(
                    x: 0.35 + Double(index % 4) * 0.08,
                    y: 0.15 + Double(index / 4) * 0.14 + timestamp * 0.002,
                    confidence: 0.92
                )
            )
        })
        return PoseFrame(timestamp: timestamp, joints: joints, bodyConfidence: 0.92)
    }
}

private struct ResearchPoseDetector: PoseDetectionService {
    let provenanceIdentifier = "test.research-pose-detector"
    let provenanceVersion = "1"

    func detectPose(in image: CGImage, at timestamp: TimeInterval) async throws -> PoseFrame? {
        if timestamp < 0.2 { throw ServeAIError.multiplePeopleDetected }
        return try await EvidencePoseDetector().detectPose(in: image, at: timestamp)
    }
}

private struct EvidencePhaseDetector: ServePhaseDetecting {
    func detect(in _: [PoseFrame]) -> [DetectedServePhase] {
        ServePhaseKind.allCases.enumerated().map { index, phase in
            DetectedServePhase(
                phase: phase,
                startTime: Double(index) * 0.2,
                endTime: Double(index + 1) * 0.2,
                confidence: 0.9
            )
        }
    }
}

private struct EvidenceVideoHasher: VideoContentHashing {
    func sha256(of _: URL) async throws -> String {
        String(repeating: "a", count: 64)
    }
}
