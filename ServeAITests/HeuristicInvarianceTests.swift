import Foundation
import XCTest
@testable import ServeAI

final class HeuristicInvarianceTests: XCTestCase {
    func testNormalizedPhaseScoresAreInvariantToCropTranslationAndScale() {
        let original = syntheticServe()
        let transformed = original.map { affineTransform($0, scale: 0.55, xOffset: 0.27, yOffset: 0.19) }
        let phases = syntheticPhases(timeScale: 1)
        let scorer = HeuristicPhaseScorer()

        let originalScores = scorer.score(frames: original, phases: phases, cameraAngle: .rear)
        let transformedScores = scorer.score(frames: transformed, phases: phases, cameraAngle: .rear)

        for phase in [
            ServePhaseKind.ballToss,
            .loading,
            .legDrive,
            .racketDrop,
            .upwardAcceleration,
            .contactPosition,
            .landingFollowThrough
        ] {
            XCTAssertEqual(score(phase, in: originalScores), score(phase, in: transformedScores), "\(phase) changed after an affine crop transform")
        }
    }

    func testPhaseScoresDoNotChangeWhenTimestampsAreDilated() {
        let original = syntheticServe()
        let slowed = original.map {
            PoseFrame(
                id: $0.id,
                timestamp: $0.timestamp * 2,
                joints: $0.joints,
                bodyConfidence: $0.bodyConfidence
            )
        }
        let scorer = HeuristicPhaseScorer()
        let normalScores = scorer.score(
            frames: original,
            phases: syntheticPhases(timeScale: 1),
            cameraAngle: .rear
        )
        let slowedScores = scorer.score(
            frames: slowed,
            phases: syntheticPhases(timeScale: 2),
            cameraAngle: .rear
        )

        for phase in ServePhaseKind.allCases {
            XCTAssertEqual(
                score(phase, in: normalScores),
                score(phase, in: slowedScores),
                "\(phase) changed when only timestamps were dilated"
            )
        }
    }

    func testTechnicalMeasurementsAreInvariantToCropTranslationAndScale() {
        let original = syntheticServe()
        let transformed = original.map { affineTransform($0, scale: 0.55, xOffset: 0.27, yOffset: 0.19) }
        let phases = syntheticPhases(timeScale: 1)
        let calculator = ServeMetricsCalculator()
        let originalMetrics = calculator.calculate(
            frames: original,
            phases: phases,
            cameraAngle: .rear
        )
        let transformedMetrics = calculator.calculate(
            frames: transformed,
            phases: phases,
            cameraAngle: .rear
        )

        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: originalMetrics.map { ($0.title, $0.value) }),
            Dictionary(uniqueKeysWithValues: transformedMetrics.map { ($0.title, $0.value) })
        )
    }

    func testTossArmAndHittingArmDoNotSwapAcrossServeEvents() {
        let scores = HeuristicPhaseScorer().score(
            frames: syntheticServe(),
            phases: syntheticPhases(timeScale: 1),
            cameraAngle: .rear
        )
        let toss = scores.first { $0.phase == .ballToss }
        let contact = scores.first { $0.phase == .contactPosition }

        XCTAssertNotNil(toss?.score)
        XCTAssertNotNil(contact?.score)
        XCTAssertTrue(toss?.note.contains("Toss-arm proxy") == true)
        XCTAssertTrue(contact?.note.contains("Likely-contact proxy") == true)
    }

    private func syntheticServe() -> [PoseFrame] {
        (0..<12).map { index in
            let progress = Double(index) / 11
            let rootY = 0.45
                - 0.045 * sin(min(1, progress / 0.45) * .pi)
                + max(0, progress - 0.40) * 0.20
            let neck = point(0.50, rootY + 0.23)
            let leftShoulder = point(0.42, rootY + 0.18)
            let rightShoulder = point(0.58, rootY + 0.18)

            let leftWristY: Double
            if progress <= 0.35 {
                leftWristY = leftShoulder.y - 0.06 + progress / 0.35 * 0.38
            } else {
                leftWristY = leftShoulder.y + max(0.03, 0.32 - (progress - 0.35) * 0.48)
            }
            let leftWrist = point(0.39, leftWristY)
            let leftElbow = midpoint(leftShoulder, leftWrist)

            let rightWristY: Double
            if progress < 0.55 {
                rightWristY = rightShoulder.y - 0.13
            } else if progress < 0.88 {
                rightWristY = rightShoulder.y - 0.13 + (progress - 0.55) / 0.33 * 0.52
            } else {
                rightWristY = rightShoulder.y + 0.34 - (progress - 0.88) * 0.45
            }
            let rightWrist = point(progress < 0.88 ? 0.63 : 0.73, rightWristY)
            let rightElbow = midpoint(rightShoulder, rightWrist)

            let kneeInterior = 108 + max(0, progress - 0.40) / 0.60 * 55
            let leftLeg = leg(hipX: 0.46, hipY: rootY - 0.04, interiorAngle: kneeInterior, direction: -1)
            let rightLeg = leg(hipX: 0.54, hipY: rootY - 0.04, interiorAngle: kneeInterior, direction: 1)

            return PoseFrame(
                timestamp: Double(index) * 0.1,
                joints: [
                    .root: point(0.50, rootY),
                    .neck: neck,
                    .leftShoulder: leftShoulder,
                    .leftElbow: leftElbow,
                    .leftWrist: leftWrist,
                    .rightShoulder: rightShoulder,
                    .rightElbow: rightElbow,
                    .rightWrist: rightWrist,
                    .leftHip: leftLeg.hip,
                    .leftKnee: leftLeg.knee,
                    .leftAnkle: leftLeg.ankle,
                    .rightHip: rightLeg.hip,
                    .rightKnee: rightLeg.knee,
                    .rightAnkle: rightLeg.ankle
                ],
                bodyConfidence: 0.9
            )
        }
    }

    private func syntheticPhases(timeScale: Double) -> [DetectedServePhase] {
        let ranges: [(ServePhaseKind, Double, Double)] = [
            (.startingStance, 0.0, 0.1),
            (.ballToss, 0.0, 0.4),
            (.loading, 0.1, 0.5),
            (.trophyPosition, 0.3, 0.6),
            (.legDrive, 0.5, 0.7),
            (.racketDrop, 0.5, 0.6),
            (.upwardAcceleration, 0.6, 0.8),
            (.contactPosition, 0.8, 0.9),
            (.pronation, 0.9, 1.0),
            (.landingFollowThrough, 0.9, 1.1)
        ]
        return ranges.map {
            DetectedServePhase(
                phase: $0.0,
                startTime: $0.1 * timeScale,
                endTime: $0.2 * timeScale,
                confidence: 0.9
            )
        }
    }

    private func affineTransform(
        _ frame: PoseFrame,
        scale: Double,
        xOffset: Double,
        yOffset: Double
    ) -> PoseFrame {
        PoseFrame(
            id: frame.id,
            timestamp: frame.timestamp,
            joints: frame.joints.mapValues {
                PosePoint(
                    x: xOffset + $0.x * scale,
                    y: yOffset + $0.y * scale,
                    confidence: $0.confidence
                )
            },
            bodyConfidence: frame.bodyConfidence
        )
    }

    private func leg(
        hipX: Double,
        hipY: Double,
        interiorAngle: Double,
        direction: Double
    ) -> (hip: PosePoint, knee: PosePoint, ankle: PosePoint) {
        let hip = point(hipX, hipY)
        let knee = point(hipX, hipY - 0.15)
        let radians = interiorAngle * .pi / 180
        let ankle = point(
            hipX + direction * sin(radians) * 0.16,
            knee.y + cos(radians) * 0.16
        )
        return (hip, knee, ankle)
    }

    private func midpoint(_ first: PosePoint, _ second: PosePoint) -> PosePoint {
        point((first.x + second.x) / 2, (first.y + second.y) / 2)
    }

    private func point(_ x: Double, _ y: Double) -> PosePoint {
        PosePoint(x: x, y: y, confidence: 0.9)
    }

    private func score(_ phase: ServePhaseKind, in scores: [PhaseScore]) -> Int? {
        scores.first { $0.phase == phase }?.score
    }
}
