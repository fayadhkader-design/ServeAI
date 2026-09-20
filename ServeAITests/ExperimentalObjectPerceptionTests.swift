import XCTest
@testable import ServeAI

final class ExperimentalObjectPerceptionTests: XCTestCase {
    private func racket(_ confidence: Double, x: Double, y: Double = 0.5) -> ObjectDetectionCandidate {
        ObjectDetectionCandidate(
            label: "tennis_racket", confidence: confidence,
            xmin: x - 0.02, xmax: x + 0.02,
            ymin: y - 0.02, ymax: y + 0.02
        )
    }

    func testSequenceSelectorChoosesOneSpatiallyConsistentRacketPerObservedFrame() {
        let frames = [
            [racket(0.95, x: 0.4)],
            [racket(0.90, x: 0.42), racket(0.94, x: 0.8)],
            [racket(0.91, x: 0.45)]
        ]
        let selected = ObjectDetectionSequenceSelector.select(
            frames: frames, label: "tennis_racket", minimumConfidence: 0.8
        )
        XCTAssertEqual(selected.count, 3)
        XCTAssertEqual(selected[1].candidate.centerX, 0.42, accuracy: 0.0001)
        XCTAssertEqual(selected.map(\.linkedToPrevious), [false, true, true])
    }

    func testSequenceSelectorDoesNotFillMissingFramesOrClaimContinuityAcrossLongGaps() {
        let frames = [[racket(0.95, x: 0.4)], [], [], [racket(0.9, x: 0.41)]]
        let selected = ObjectDetectionSequenceSelector.select(
            frames: frames, label: "tennis_racket", minimumConfidence: 0.8
        )
        XCTAssertEqual(selected.map(\.frameIndex), [0, 3])
        XCTAssertFalse(selected[1].linkedToPrevious)
    }

    func testSequenceSelectorRejectsInvalidAndLowConfidenceBoxes() {
        let invalid = ObjectDetectionCandidate(
            label: "tennis_racket", confidence: 0.99,
            xmin: 0.8, xmax: 0.2, ymin: 0.4, ymax: 0.6
        )
        let selected = ObjectDetectionSequenceSelector.select(
            frames: [[invalid, racket(0.79, x: 0.5)]],
            label: "tennis_racket", minimumConfidence: 0.8
        )
        XCTAssertTrue(selected.isEmpty)
    }

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

    func testCropBoxMapsToFullFrameBeforeTemporalAssociation() {
        let box = PoseCenteredObjectROI.fullFrameBox(
            for: CGRect(x: 0.25, y: 0.5, width: 0.25, height: 0.25),
            crop: CGRect(x: 200, y: 400, width: 400, height: 400),
            imageWidth: 1_000, imageHeight: 2_000
        )
        XCTAssertEqual(box.minX, 0.3, accuracy: 0.0001)
        XCTAssertEqual(box.maxX, 0.4, accuracy: 0.0001)
        XCTAssertEqual(box.minY, 0.7, accuracy: 0.0001)
        XCTAssertEqual(box.maxY, 0.75, accuracy: 0.0001)
    }

    func testExperimentalCoverageIsTransparentAndBounded() {
        let summary = ExperimentalObjectPerceptionSummary(
            modelIdentifier: "pilot", confidenceThreshold: 0.8,
            sampledFrameCount: 10, directPoseFrameCount: 8, fallbackPoseFrameCount: 2,
            ballDetectedFrameCount: 7, racketDetectedFrameCount: 4,
            ballLinkedFrameCount: 5, racketLinkedFrameCount: 2
        )
        XCTAssertEqual(summary.ballTrackCoverage, 0.7, accuracy: 0.0001)
        XCTAssertEqual(summary.racketTrackCoverage, 0.4, accuracy: 0.0001)
    }
}
