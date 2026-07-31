import XCTest
@testable import ServeAI

final class ScoringAndConfidenceTests: XCTestCase {
    func testScoreWeightingRebalancesMissingPhases() {
        let phases = [
            PhaseScore(phase: .ballToss, score: 80, confidence: .high, note: ""),
            PhaseScore(phase: .contactPosition, score: 60, confidence: .high, note: ""),
            PhaseScore(phase: .racketDrop, score: nil, confidence: .low, note: "Insufficient visibility")
        ]
        XCTAssertEqual(ScoreCalculator().weightedScore(for: phases), 70)
    }

    func testScoreIsNilWhenNothingIsMeasurable() {
        let phases = [PhaseScore(phase: .pronation, score: nil, confidence: .low, note: "")]
        XCTAssertNil(ScoreCalculator().weightedScore(for: phases))
    }

    func testLowConfidenceProxyDoesNotDistortOverallScore() {
        let phases = [
            PhaseScore(phase: .contactPosition, score: 92, confidence: .high, note: ""),
            PhaseScore(phase: .pronation, score: 20, confidence: .low, note: "")
        ]

        XCTAssertEqual(ScoreCalculator().weightedScore(for: phases), 92)
    }

    func testConfidenceThresholds() {
        let calculator = AnalysisConfidenceCalculator()
        let high = calculator.calculate(visibility: 0.95, poseQuality: 0.9, usableFrames: 90, expectedFrames: 100, cameraSuitability: 0.9, missingAreas: [])
        XCTAssertEqual(high.level, .high)
        XCTAssertEqual(high.percentage, Int((high.evidenceScore * 100).rounded()))
        XCTAssertEqual(high.evidenceQualityTitle, "High video evidence")

        let low = calculator.calculate(visibility: 0.25, poseQuality: 0.3, usableFrames: 10, expectedFrames: 100, cameraSuitability: 0.4, missingAreas: ["feet"])
        XCTAssertEqual(low.level, .low)
        XCTAssertEqual(low.missingAreas, ["feet"])
    }

    func testSourceAssuranceNeverEquatesClearVideoWithCorrectCoaching() {
        XCTAssertTrue(AnalysisSource.vision.assuranceDetail.contains("not whether"))
        XCTAssertTrue(AnalysisSource.experimentalCoreML.assuranceDetail.contains("failed"))
        XCTAssertTrue(AnalysisSource.evaluationCoreML.assuranceDetail.contains("not released"))
        XCTAssertTrue(AnalysisSource.coreML.assuranceDetail.contains("does not guarantee"))
    }
}
