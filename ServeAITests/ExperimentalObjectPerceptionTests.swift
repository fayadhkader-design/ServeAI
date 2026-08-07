import XCTest
@testable import ServeAI

final class ExperimentalObjectPerceptionTests: XCTestCase {
    func testPoseCenteredROIMatchesFrozenTrainingContract() throws {
        let pose = PoseFrame(
            timestamp: 1,
            joints: [
                .root: PosePoint(x: 0.6, y: 0.5, confidence: 0.9),
                .nose: PosePoint(x: 0.6, y: 0.6, confidence: 0.9)
            ],
            bodyConfidence: 0.9
        )
        let roi = try XCTUnwrap(PoseCenteredObjectROI.rectangle(for: pose, imageWidth: 1_000, imageHeight: 2_000))
        XCTAssertEqual(roi.width, roi.height)
        XCTAssertGreaterThanOrEqual(roi.minX, 0)
        XCTAssertGreaterThanOrEqual(roi.minY, 0)
        XCTAssertLessThanOrEqual(roi.maxX, 1_000)
        XCTAssertLessThanOrEqual(roi.maxY, 2_000)
        XCTAssertLessThan(roi.midY, 1_000)
    }

    func testExperimentalCoverageIsTransparentAndBounded() {
        let summary = ExperimentalObjectPerceptionSummary(
            modelIdentifier: "pilot", confidenceThreshold: 0.8,
            sampledFrameCount: 10, directPoseFrameCount: 8, fallbackPoseFrameCount: 2,
            ballDetectedFrameCount: 7, racketDetectedFrameCount: 4
        )
        XCTAssertEqual(summary.ballTrackCoverage, 0.7, accuracy: 0.0001)
        XCTAssertEqual(summary.racketTrackCoverage, 0.4, accuracy: 0.0001)
    }
}
