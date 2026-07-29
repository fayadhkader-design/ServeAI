import XCTest
@testable import ServeAI

final class ModelEvaluationTests: XCTestCase {
    func testEvaluationCalculatesKnownMetrics() {
        let report = ServeModelEvaluator().evaluate(
            quality: [
                .init(groundTruthUsable: true, predictedUsable: true),
                .init(groundTruthUsable: true, predictedUsable: true),
                .init(groundTruthUsable: true, predictedUsable: false),
                .init(groundTruthUsable: false, predictedUsable: true)
            ],
            boundaries: [
                .init(phase: .ballToss, groundTruthStart: 1, predictedStart: 1.1, groundTruthEnd: 2, predictedEnd: 1.9)
            ],
            phaseVisibility: [
                .init(phase: .ballToss, groundTruthVisible: true, predictedVisible: true),
                .init(phase: .contactPosition, groundTruthVisible: true, predictedVisible: false),
                .init(phase: .pronation, groundTruthVisible: false, predictedVisible: true)
            ],
            techniqueRatings: [
                .init(label: .contactReach, groundTruthRating: 4, predictedRating: 3),
                .init(label: .landingBalance, groundTruthRating: 3, predictedRating: 3)
            ],
            priorities: [
                .init(groundTruth: .legDriveTiming, predicted: .legDriveTiming),
                .init(groundTruth: .landingBalance, predicted: .contactReach)
            ],
            repeatability: [
                .init(firstScore: 70, repeatedScore: 74),
                .init(firstScore: 70, repeatedScore: 77)
            ],
            design: .unverified
        )

        XCTAssertEqual(report.qualityPrecision, 2.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(report.qualityRecall, 2.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(report.boundaryMeanAbsoluteError, 0.1, accuracy: 0.001)
        XCTAssertEqual(report.phaseVisibilityF1, 0.5, accuracy: 0.001)
        XCTAssertEqual(report.techniqueRatingMeanAbsoluteError, 0.5, accuracy: 0.001)
        XCTAssertEqual(report.priorityAgreement, 0.5, accuracy: 0.001)
        XCTAssertEqual(report.repeatabilityWithinFivePoints, 0.5, accuracy: 0.001)
        XCTAssertFalse(report.passes)
    }

    func testPerfectEvaluationPassesAcceptanceCriteria() {
        let quality = Array(repeating: BinaryQualityEvaluation(groundTruthUsable: true, predictedUsable: true), count: 60)
        let boundaries = Array(
            repeating: PhaseBoundaryEvaluation(
                phase: .contactPosition,
                groundTruthStart: 2,
                predictedStart: 2.02,
                groundTruthEnd: 2.1,
                predictedEnd: 2.12
            ),
            count: 60
        )
        let priorities = Array(
            repeating: PriorityEvaluation(groundTruth: .contactReach, predicted: .contactReach),
            count: 60
        )
        let repeatability = Array(
            repeating: RepeatabilityEvaluation(firstScore: 80, repeatedScore: 82),
            count: 30
        )
        let report = ServeModelEvaluator().evaluate(
            quality: quality,
            boundaries: boundaries,
            phaseVisibility: Array(
                repeating: .init(phase: .contactPosition, groundTruthVisible: true, predictedVisible: true),
                count: 60
            ),
            techniqueRatings: Array(
                repeating: .init(label: .contactReach, groundTruthRating: 4, predictedRating: 4),
                count: 60
            ),
            priorities: priorities,
            repeatability: repeatability,
            design: ModelEvaluationDesign(
                uniquePlayerCount: 12,
                usesPlayerHeldOutSplit: true,
                allClipsHaveTrainingConsent: true,
                provenanceVerified: true,
                auditedSubgroupDimensions: Set(EvaluationSubgroupDimension.allCases),
                failedMaterialSubgroups: []
            )
        )

        XCTAssertTrue(report.passes)
        XCTAssertTrue(report.failedCriteria().isEmpty)
    }

    func testPerfectMetricsStillFailWithoutRequiredEvaluationDesign() {
        let report = ServeModelEvaluator().evaluate(
            quality: Array(repeating: .init(groundTruthUsable: true, predictedUsable: true), count: 60),
            boundaries: Array(
                repeating: .init(
                    phase: .contactPosition,
                    groundTruthStart: 2,
                    predictedStart: 2,
                    groundTruthEnd: 2.1,
                    predictedEnd: 2.1
                ),
                count: 60
            ),
            phaseVisibility: Array(
                repeating: .init(phase: .contactPosition, groundTruthVisible: true, predictedVisible: true),
                count: 60
            ),
            techniqueRatings: Array(
                repeating: .init(label: .contactReach, groundTruthRating: 4, predictedRating: 4),
                count: 60
            ),
            priorities: Array(repeating: .init(groundTruth: .contactReach, predicted: .contactReach), count: 60),
            repeatability: Array(repeating: .init(firstScore: 80, repeatedScore: 80), count: 30),
            design: .unverified
        )

        XCTAssertFalse(report.passes)
        XCTAssertTrue(report.failedCriteria().contains("player-held-out split"))
        XCTAssertTrue(report.failedCriteria().contains("training consent verification"))
        XCTAssertTrue(report.failedCriteria().contains("subgroup coverage"))
    }
}
