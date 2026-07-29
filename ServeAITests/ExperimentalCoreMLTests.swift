import XCTest
@testable import ServeAI

final class ExperimentalCoreMLTests: XCTestCase {
    func testBundledExperimentalModelRunsWithoutClaimingValidation() async throws {
        let frames = (0..<24).map { index in
            ServeModelFrameFeature(
                timestamp: 3 * Double(index) / 23,
                bodyConfidence: 0.9,
                joints: BodyJoint.allCases.enumerated().map { jointIndex, joint in
                    ServeModelJointFeature(
                        joint: joint,
                        x: Double(jointIndex % 4) * 0.08 - 0.12,
                        y: Double(index) * 0.015 + Double(jointIndex / 4) * 0.07,
                        confidence: 0.9,
                        isPresent: true
                    )
                }
            )
        }
        let sequence = ServeModelFeatureSequence(
            duration: 3,
            cameraAngle: .side,
            frames: frames
        )

        let prediction = try await BundledExperimentalServeInferenceModel().predict(
            features: sequence,
            skillLevel: .intermediate
        )

        XCTAssertEqual(prediction.modelIdentifier, "serveai.thetis-pseudo-coach")
        XCTAssertEqual(prediction.modelVersion, "0.2.0-research")
        XCTAssertEqual(prediction.modelArtifactSHA256?.count, 64)
        XCTAssertFalse(prediction.validatedReleaseVerified)
        XCTAssertGreaterThanOrEqual(prediction.detectedPhases.count, 6)
        XCTAssertNil(prediction.phaseScores.first { $0.phase == .racketDrop }?.score)
        XCTAssertNil(prediction.phaseScores.first { $0.phase == .pronation }?.score)
        XCTAssertEqual(AnalysisSource.experimentalCoreML.title, "Experimental on-device model")
        XCTAssertTrue(AnalysisSource.experimentalCoreML.detail.contains("failed"))
    }
}
