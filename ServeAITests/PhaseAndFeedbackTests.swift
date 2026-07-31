import XCTest
@testable import ServeAI

final class PhaseAndFeedbackTests: XCTestCase {
    func testPhaseSequenceIsCompleteAndChronological() {
        let frames = (0..<40).map { index -> PoseFrame in
            let progress = Double(index) / 39
            let wristY = index < 14 ? 0.25 + progress : (index < 24 ? 0.85 - progress * 0.5 : 0.3 + progress * 0.7)
            let joints: [BodyJoint: PosePoint] = [
                .root: PosePoint(x: 0.5, y: 0.45 - sin(progress * .pi) * 0.08, confidence: 0.9),
                .leftWrist: PosePoint(x: 0.45, y: wristY, confidence: 0.9),
                .rightWrist: PosePoint(x: 0.62, y: wristY * 0.85, confidence: 0.8)
            ]
            return PoseFrame(timestamp: Double(index) * 0.05, joints: joints, bodyConfidence: 0.85)
        }
        let phases = HeuristicServePhaseDetector().detect(in: frames)
        XCTAssertEqual(phases.map(\.phase), ServePhaseKind.allCases)
        XCTAssertEqual(phases.count, 10)
        for pair in zip(phases, phases.dropFirst()) {
            XCTAssertLessThanOrEqual(pair.0.startTime, pair.0.endTime)
            XCTAssertLessThanOrEqual(pair.0.endTime, pair.1.endTime)
        }
    }

    func testFeedbackChoosesPriorityAndAtMostThreeDrills() {
        let phases = [
            PhaseScore(phase: .ballToss, score: 52, confidence: .medium, note: "Toss remained behind the shoulder."),
            PhaseScore(phase: .landingFollowThrough, score: 88, confidence: .high, note: "Balanced finish."),
            PhaseScore(phase: .racketDrop, score: nil, confidence: .low, note: "Insufficient visibility.")
        ]
        let generator = ServeFeedbackGenerator()
        let insights = generator.generate(from: phases, metrics: [], skillLevel: .intermediate)
        XCTAssertTrue(insights.contains { $0.severity == .priority && $0.relatedPhase == .ballToss })
        XCTAssertTrue(insights.contains { $0.severity == .strength })
        XCTAssertLessThanOrEqual(generator.selectDrills(for: insights, skillLevel: .intermediate).count, 3)
    }

    func testModelPriorityControlsDisplayedPriorityWhenTechniqueIsSupported() {
        let phases = [
            PhaseScore(phase: .loading, score: 35, confidence: .medium, note: "Load score."),
            PhaseScore(phase: .contactPosition, score: 72, confidence: .medium, note: "Contact score."),
        ]

        let insights = ServeFeedbackGenerator().generate(
            from: phases,
            metrics: [],
            skillLevel: .intermediate,
            preferredPriority: .contactReach
        )

        XCTAssertEqual(insights.first(where: { $0.severity == .priority })?.relatedPhase, .contactPosition)
    }

    func testUnsupportedModelPriorityFallsBackToWeakestMeasurablePhase() {
        let phases = [
            PhaseScore(phase: .loading, score: 35, confidence: .medium, note: "Load score."),
            PhaseScore(phase: .contactPosition, score: 72, confidence: .medium, note: "Contact score."),
        ]

        let insights = ServeFeedbackGenerator().generate(
            from: phases,
            metrics: [],
            skillLevel: .intermediate,
            preferredPriority: .tossPlacement
        )

        XCTAssertEqual(insights.first(where: { $0.severity == .priority })?.relatedPhase, .loading)
    }

    func testLowConfidenceMinimumCannotBecomeCoachingPriority() {
        let phases = [
            PhaseScore(phase: .trophyPosition, score: 25, confidence: .low, note: "Projection-sensitive estimate."),
            PhaseScore(phase: .contactPosition, score: 81, confidence: .high, note: "Contact is visible."),
            PhaseScore(phase: .landingFollowThrough, score: 78, confidence: .medium, note: "Landing is visible.")
        ]

        let insights = ServeFeedbackGenerator().generate(
            from: phases,
            metrics: [],
            skillLevel: .advanced
        )

        XCTAssertEqual(
            insights.first(where: { $0.severity == .priority })?.relatedPhase,
            .landingFollowThrough
        )
    }
}
