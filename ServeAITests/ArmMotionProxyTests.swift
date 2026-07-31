import XCTest
@testable import ServeAI

final class ArmMotionProxyTests: XCTestCase {
    func testVisibleArmProducesRacketDropAndPronationProxies() {
        let frames = [
            frame(time: 0.00, rightElbow: (0.64, 0.68), rightWrist: (0.63, 0.38)),
            frame(time: 0.10, rightElbow: (0.65, 0.70), rightWrist: (0.64, 0.42)),
            frame(time: 0.20, rightElbow: (0.66, 0.74), rightWrist: (0.67, 0.88)),
            frame(time: 0.30, rightElbow: (0.66, 0.75), rightWrist: (0.68, 0.94)),
            frame(time: 0.40, rightElbow: (0.66, 0.75), rightWrist: (0.78, 0.82)),
            frame(time: 0.50, rightElbow: (0.66, 0.75), rightWrist: (0.80, 0.72)),
        ]
        let phases = [
            phase(.legDrive, 0.00, 0.10),
            phase(.racketDrop, 0.10, 0.20),
            phase(.upwardAcceleration, 0.20, 0.30),
            phase(.contactPosition, 0.30, 0.35),
            phase(.pronation, 0.35, 0.50),
        ]

        let scores = HeuristicPhaseScorer().score(frames: frames, phases: phases)
        let racketDrop = scores.first { $0.phase == .racketDrop }
        let pronation = scores.first { $0.phase == .pronation }

        XCTAssertNotNil(racketDrop?.score)
        XCTAssertNotNil(pronation?.score)
        XCTAssertEqual(racketDrop?.confidence, .medium)
        XCTAssertEqual(pronation?.confidence, .medium)
        XCTAssertTrue(racketDrop?.note.contains("Wrist-drop proxy") == true)
        XCTAssertTrue(pronation?.note.contains("Forearm-path proxy") == true)
    }

    func testMissingArmEvidenceRemainsUnavailable() {
        let frames = (0..<4).map { index in
            PoseFrame(
                timestamp: Double(index) * 0.1,
                joints: [
                    .neck: point(0.5, 0.72),
                    .root: point(0.5, 0.48),
                    .leftHip: point(0.45, 0.46),
                    .rightHip: point(0.55, 0.46),
                    .leftKnee: point(0.45, 0.30),
                    .rightKnee: point(0.55, 0.30),
                ],
                bodyConfidence: 0.9
            )
        }
        let phases = [
            phase(.racketDrop, 0.0, 0.2),
            phase(.contactPosition, 0.2, 0.2),
            phase(.pronation, 0.2, 0.3),
        ]

        let scores = HeuristicPhaseScorer().score(frames: frames, phases: phases)

        XCTAssertNil(scores.first { $0.phase == .racketDrop }?.score)
        XCTAssertNil(scores.first { $0.phase == .pronation }?.score)
    }

    func testSingleWristSpikeDoesNotMaxOutRacketDropProxy() {
        let frames = [
            frame(time: 0.00, rightElbow: (0.64, 0.68), rightWrist: (0.63, 0.50)),
            frame(time: 0.10, rightElbow: (0.64, 0.68), rightWrist: (0.63, 0.52)),
            frame(time: 0.20, rightElbow: (0.64, 0.68), rightWrist: (0.63, 0.10)),
            frame(time: 0.30, rightElbow: (0.66, 0.75), rightWrist: (0.68, 0.94)),
            frame(time: 0.40, rightElbow: (0.66, 0.75), rightWrist: (0.78, 0.82)),
            frame(time: 0.50, rightElbow: (0.66, 0.75), rightWrist: (0.80, 0.72)),
        ]
        let phases = [
            phase(.legDrive, 0.00, 0.10),
            phase(.racketDrop, 0.10, 0.20),
            phase(.upwardAcceleration, 0.20, 0.30),
            phase(.contactPosition, 0.30, 0.35),
            phase(.pronation, 0.35, 0.50),
        ]

        let score = HeuristicPhaseScorer()
            .score(frames: frames, phases: phases)
            .first { $0.phase == .racketDrop }?
            .score

        XCTAssertNotNil(score)
        XCTAssertLessThan(score ?? 100, 90)
    }

    private func frame(
        time: TimeInterval,
        rightElbow: (Double, Double),
        rightWrist: (Double, Double)
    ) -> PoseFrame {
        PoseFrame(
            timestamp: time,
            joints: [
                .neck: point(0.50, 0.72),
                .root: point(0.50, 0.48),
                .leftShoulder: point(0.42, 0.66),
                .leftElbow: point(0.40, 0.56),
                .leftWrist: point(0.43, 0.52),
                .rightShoulder: point(0.60, 0.66),
                .rightElbow: point(rightElbow.0, rightElbow.1),
                .rightWrist: point(rightWrist.0, rightWrist.1),
                .leftHip: point(0.45, 0.46),
                .rightHip: point(0.55, 0.46),
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

    private static func point(_ x: Double, _ y: Double) -> PosePoint {
        PosePoint(x: x, y: y, confidence: 0.9)
    }

    private func point(_ x: Double, _ y: Double) -> PosePoint {
        Self.point(x, y)
    }
}
