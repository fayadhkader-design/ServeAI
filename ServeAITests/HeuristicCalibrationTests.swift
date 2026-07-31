import Foundation
import XCTest
@testable import ServeAI

final class HeuristicCalibrationTests: XCTestCase {
    func testSingleExtremeKneeFrameDoesNotCreateLoadingBreakdown() {
        let frames = [51, 108, 110, 112, 114].enumerated().map { index, angle in
            frame(time: Double(index), kneeInteriorAngle: Double(angle), shoulderLineAngle: 30)
        }
        let scores = HeuristicPhaseScorer().score(
            frames: frames,
            phases: [phase(.loading, 0, 4)],
            cameraAngle: .rear
        )
        let loading = scores.first { $0.phase == .loading }

        XCTAssertEqual(loading?.score, 90)
        XCTAssertTrue(loading?.note.contains("isolated extreme frames were excluded") == true)
    }

    func testOnlyImplausibleKneeFramesAreReportedUnavailable() {
        let frames = (0..<5).map {
            frame(time: Double($0), kneeInteriorAngle: 51, shoulderLineAngle: 30)
        }
        let scores = HeuristicPhaseScorer().score(
            frames: frames,
            phases: [phase(.loading, 0, 4)],
            cameraAngle: .rear
        )

        XCTAssertNil(scores.first { $0.phase == .loading }?.score)
    }

    func testReversedRearShoulderLineUsesAcuteImagePlaneTilt() {
        let frames = (0..<5).map {
            frame(time: Double($0), kneeInteriorAngle: 110, shoulderLineAngle: 107)
        }
        let scores = HeuristicPhaseScorer().score(
            frames: frames,
            phases: [phase(.trophyPosition, 0, 4)],
            cameraAngle: .rear
        )
        let trophy = scores.first { $0.phase == .trophyPosition }

        XCTAssertEqual(trophy?.score, 88)
        XCTAssertTrue(trophy?.note.contains("73°") == true)
    }

    func testSideViewShoulderTiltIsNotPresentedAs3DTechniqueGrade() {
        let frames = (0..<5).map {
            frame(time: Double($0), kneeInteriorAngle: 110, shoulderLineAngle: 35)
        }
        let scores = HeuristicPhaseScorer().score(
            frames: frames,
            phases: [phase(.trophyPosition, 0, 4)],
            cameraAngle: .side
        )

        XCTAssertNil(scores.first { $0.phase == .trophyPosition }?.score)
    }

    private func frame(
        time: TimeInterval,
        kneeInteriorAngle: Double,
        shoulderLineAngle: Double
    ) -> PoseFrame {
        let kneeRadians = kneeInteriorAngle * .pi / 180
        let shoulderRadians = shoulderLineAngle * .pi / 180
        let knee = PosePoint(x: 0.50, y: 0.40, confidence: 0.9)
        let ankle = PosePoint(
            x: 0.50 + sin(kneeRadians) * 0.20,
            y: 0.40 + cos(kneeRadians) * 0.20,
            confidence: 0.9
        )
        let leftShoulder = PosePoint(x: 0.50, y: 0.65, confidence: 0.9)
        let rightShoulder = PosePoint(
            x: 0.50 + cos(shoulderRadians) * 0.18,
            y: 0.65 + sin(shoulderRadians) * 0.18,
            confidence: 0.9
        )
        return PoseFrame(
            timestamp: time,
            joints: [
                .root: PosePoint(x: 0.5, y: 0.48, confidence: 0.9),
                .leftHip: PosePoint(x: 0.50, y: 0.60, confidence: 0.9),
                .leftKnee: knee,
                .leftAnkle: ankle,
                .leftShoulder: leftShoulder,
                .rightShoulder: rightShoulder
            ],
            bodyConfidence: 0.9
        )
    }

    private func phase(
        _ phase: ServePhaseKind,
        _ start: TimeInterval,
        _ end: TimeInterval
    ) -> DetectedServePhase {
        DetectedServePhase(
            phase: phase,
            startTime: start,
            endTime: end,
            confidence: 0.9
        )
    }
}
