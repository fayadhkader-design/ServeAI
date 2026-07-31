import XCTest
@testable import ServeAI

final class PhaseEventReliabilityTests: XCTestCase {
    func testPhaseAnchorsAreInvariantToCropTranslationAndScale() {
        let frames = syntheticServe()
        let transformed = frames.map {
            affineTransform($0, scale: 0.57, xOffset: 0.21, yOffset: 0.17)
        }

        let original = HeuristicServePhaseDetector().detect(in: frames)
        let changedCrop = HeuristicServePhaseDetector().detect(in: transformed)

        XCTAssertEqual(original.map(\.startTime), changedCrop.map(\.startTime))
        XCTAssertEqual(original.map(\.endTime), changedCrop.map(\.endTime))
        for pair in zip(original, changedCrop) {
            XCTAssertEqual(pair.0.confidence, pair.1.confidence, accuracy: 0.000_001)
        }
    }

    func testOneWristSpikeCannotMoveLikelyContactAnchor() throws {
        let frames = syntheticServe()
        var changed = frames
        let spikeIndex = 52
        var joints = changed[spikeIndex].joints
        let original = try XCTUnwrap(joints[.rightWrist])
        joints[.rightWrist] = PosePoint(
            x: original.x,
            y: 1.80,
            confidence: original.confidence
        )
        changed[spikeIndex] = PoseFrame(
            id: changed[spikeIndex].id,
            timestamp: changed[spikeIndex].timestamp,
            joints: joints,
            bodyConfidence: changed[spikeIndex].bodyConfidence
        )

        let baseline = HeuristicServePhaseDetector().detect(in: frames)
        let withSpike = HeuristicServePhaseDetector().detect(in: changed)
        let baselineContact = try XCTUnwrap(baseline.first { $0.phase == .contactPosition })
        let spikeContact = try XCTUnwrap(withSpike.first { $0.phase == .contactPosition })

        XCTAssertEqual(baselineContact.startTime, spikeContact.startTime)
        XCTAssertEqual(baselineContact.endTime, spikeContact.endTime)
    }

    func testMissingArmEventsRemainChronologicalButAreNotScored() throws {
        let frames = syntheticServe().map { frame in
            PoseFrame(
                id: frame.id,
                timestamp: frame.timestamp,
                joints: frame.joints.filter {
                    $0.key != .leftWrist && $0.key != .rightWrist
                },
                bodyConfidence: frame.bodyConfidence
            )
        }
        let phases = HeuristicServePhaseDetector().detect(in: frames)
        XCTAssertEqual(phases.count, ServePhaseKind.allCases.count)
        for pair in zip(phases, phases.dropFirst()) {
            XCTAssertLessThanOrEqual(pair.0.endTime, pair.1.endTime)
        }

        for phase in [
            ServePhaseKind.ballToss,
            .racketDrop,
            .upwardAcceleration,
            .contactPosition,
            .pronation
        ] {
            XCTAssertLessThan(
                try XCTUnwrap(phases.first { $0.phase == phase }).confidence,
                0.35,
                "\(phase) should expose missing event evidence"
            )
        }

        let scores = HeuristicPhaseScorer().score(
            frames: frames,
            phases: phases,
            cameraAngle: .rear
        )
        for phase in [
            ServePhaseKind.ballToss,
            .racketDrop,
            .upwardAcceleration,
            .contactPosition,
            .pronation
        ] {
            let score = try XCTUnwrap(scores.first { $0.phase == phase })
            XCTAssertNil(score.score)
            XCTAssertTrue(score.note.contains("fallback was not scored"))
        }
    }

    func testExplicitLowTimingConfidenceCannotProduceTechniqueScore() throws {
        let frames = syntheticServe()
        let phases = ServePhaseKind.allCases.enumerated().map { index, phase in
            DetectedServePhase(
                phase: phase,
                startTime: Double(index) * 0.20,
                endTime: Double(index + 1) * 0.20,
                confidence: 0.20
            )
        }

        let scores = HeuristicPhaseScorer().score(
            frames: frames,
            phases: phases,
            cameraAngle: .rear
        )

        XCTAssertEqual(scores.count, ServePhaseKind.allCases.count)
        XCTAssertTrue(scores.allSatisfy { $0.score == nil && $0.confidence == .low })
    }

    private func syntheticServe() -> [PoseFrame] {
        (0..<60).map { index in
            let rootY: Double
            if index <= 25 {
                rootY = 0.43 - Double(index) / 25 * 0.09
            } else if index <= 46 {
                rootY = 0.34 + Double(index - 25) / 21 * 0.19
            } else {
                rootY = 0.53 - Double(index - 46) / 13 * 0.05
            }
            let neck = point(0.50, rootY + 0.22)
            let leftShoulder = point(0.43, rootY + 0.17)
            let rightShoulder = point(0.57, rootY + 0.17)

            let leftWristY = 0.40 + 0.48 * gaussian(index, center: 17, width: 7)
            let rightWristY = 0.41
                - 0.14 * gaussian(index, center: 35, width: 5)
                + 0.55 * gaussian(index, center: 46, width: 5)
            let leftWrist = point(0.40, leftWristY)
            let rightWrist = point(index < 46 ? 0.62 : 0.68, rightWristY)

            return PoseFrame(
                timestamp: Double(index) * 0.05,
                joints: [
                    .root: point(0.50, rootY),
                    .neck: neck,
                    .leftShoulder: leftShoulder,
                    .leftElbow: midpoint(leftShoulder, leftWrist),
                    .leftWrist: leftWrist,
                    .rightShoulder: rightShoulder,
                    .rightElbow: midpoint(rightShoulder, rightWrist),
                    .rightWrist: rightWrist,
                    .leftHip: point(0.46, rootY - 0.03),
                    .rightHip: point(0.54, rootY - 0.03),
                    .leftKnee: point(0.45, 0.23),
                    .rightKnee: point(0.55, 0.23),
                    .leftAnkle: point(0.44, 0.08),
                    .rightAnkle: point(0.56, 0.08)
                ],
                bodyConfidence: 0.90
            )
        }
    }

    private func gaussian(_ index: Int, center: Int, width: Double) -> Double {
        let distance = Double(index - center) / width
        return exp(-0.5 * distance * distance)
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

    private func midpoint(_ first: PosePoint, _ second: PosePoint) -> PosePoint {
        point((first.x + second.x) / 2, (first.y + second.y) / 2)
    }

    private func point(_ x: Double, _ y: Double) -> PosePoint {
        PosePoint(x: x, y: y, confidence: 0.90)
    }
}
