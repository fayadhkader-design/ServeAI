import CryptoKit
import XCTest
@testable import ServeAI

final class ValidatedModelReleaseTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServeAIReleaseTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testValidSignedReleasePassesEveryGate() throws {
        let fixture = try makeFixture()

        let verified = try fixture.verifier.verify(
            envelopeData: fixture.envelopeData,
            modelURL: fixture.modelURL,
            evaluationURL: fixture.evaluationURL,
            rightsEvidenceURL: fixture.rightsURL
        )

        XCTAssertEqual(verified.payload.modelIdentifier, "serveai.synthetic-validation-test")
        XCTAssertTrue(verified.evaluation.failedCriteria().isEmpty)
        XCTAssertEqual(verified.modelURL, fixture.modelURL)
    }

    func testUnknownSelfSignedAuthorityIsRejected() throws {
        let fixture = try makeFixture()
        let verifier = ValidatedModelReleaseVerifier(pinnedPublicKeysX963: [:])

        XCTAssertThrowsError(try verifier.verify(
            envelopeData: fixture.envelopeData,
            modelURL: fixture.modelURL,
            evaluationURL: fixture.evaluationURL,
            rightsEvidenceURL: fixture.rightsURL
        )) { error in
            XCTAssertEqual(error as? ModelReleaseVerificationError, .unknownSigningKey)
        }
    }

    func testTamperedModelIsRejectedEvenWhenManifestStillSaysPass() throws {
        let fixture = try makeFixture()
        try Data("tampered model".utf8).write(to: fixture.modelURL)

        XCTAssertThrowsError(try fixture.verifier.verify(
            envelopeData: fixture.envelopeData,
            modelURL: fixture.modelURL,
            evaluationURL: fixture.evaluationURL,
            rightsEvidenceURL: fixture.rightsURL
        )) { error in
            XCTAssertEqual(
                error as? ModelReleaseVerificationError,
                .artifactDigestMismatch("model")
            )
        }
    }

    func testSignedReleaseStillFailsWhenPriorityAccuracyMissesGate() throws {
        let fixture = try makeFixture(priorityAgreement: 0.74)

        XCTAssertThrowsError(try fixture.verifier.verify(
            envelopeData: fixture.envelopeData,
            modelURL: fixture.modelURL,
            evaluationURL: fixture.evaluationURL,
            rightsEvidenceURL: fixture.rightsURL
        )) { error in
            guard case .failedReleaseGates(let failures) = error as? ModelReleaseVerificationError else {
                return XCTFail("Expected a failed-gates error, got \(error)")
            }
            XCTAssertTrue(failures.contains("coach priority agreement"))
        }
    }

    func testReleaseFailsWithoutCommercialTrainingGrant() throws {
        let fixture = try makeFixture(commercialTrainingGranted: false)

        XCTAssertThrowsError(try fixture.verifier.verify(
            envelopeData: fixture.envelopeData,
            modelURL: fixture.modelURL,
            evaluationURL: fixture.evaluationURL,
            rightsEvidenceURL: fixture.rightsURL
        )) { error in
            guard case .failedReleaseGates(let failures) = error as? ModelReleaseVerificationError else {
                return XCTFail("Expected a failed-gates error, got \(error)")
            }
            XCTAssertEqual(failures, ["commercial-use rights evidence"])
        }
    }

    func testSignedReleaseBoundToDifferentCoachRubricIsRejected() throws {
        let fixture = try makeFixture(rubric: CoachRubricBinding(
            identifier: CoachAnnotationRubric.identifier,
            version: "1.0.1",
            sha256: CoachAnnotationRubric.sha256
        ))

        XCTAssertThrowsError(try fixture.verifier.verify(
            envelopeData: fixture.envelopeData,
            modelURL: fixture.modelURL,
            evaluationURL: fixture.evaluationURL,
            rightsEvidenceURL: fixture.rightsURL
        )) { error in
            guard case .failedReleaseGates(let failures) = error as? ModelReleaseVerificationError else {
                return XCTFail("Expected a failed-gates error, got \(error)")
            }
            XCTAssertTrue(failures.contains("coach rubric"))
        }
    }

    func testSignedReleaseBoundToDifferentCapturePlanIsRejected() throws {
        let fixture = try makeFixture(capturePlan: CapturePlanBinding(
            identifier: CapturePlanAssignment.currentPlan.identifier,
            version: "1.0.1",
            sha256: CapturePlanAssignment.currentPlan.sha256
        ))

        XCTAssertThrowsError(try fixture.verifier.verify(
            envelopeData: fixture.envelopeData,
            modelURL: fixture.modelURL,
            evaluationURL: fixture.evaluationURL,
            rightsEvidenceURL: fixture.rightsURL
        )) { error in
            guard case .failedReleaseGates(let failures) = error as? ModelReleaseVerificationError else {
                return XCTFail("Expected a failed-gates error, got \(error)")
            }
            XCTAssertTrue(failures.contains("capture plan"))
        }
    }

    func testProductionAuthorityListStartsEmptyAndValidatedModeFailsClosed() {
        XCTAssertTrue(BundledValidatedModelReleaseLoader.productionPinnedPublicKeysX963.isEmpty)
        XCTAssertEqual(
            ServiceFactory.analysisService(
                configuration: AppConfiguration(analysisMode: .coreML)
            ).source,
            .coreML
        )
    }

    func testCompiledModelDirectoryHashMatchesReleaseToolContract() throws {
        let directory = temporaryDirectory.appendingPathComponent("Synthetic.mlmodelc", isDirectory: true)
        let nested = directory.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("alpha".utf8).write(to: directory.appendingPathComponent("a.bin"))
        try Data("beta".utf8).write(to: nested.appendingPathComponent("b.bin"))

        XCTAssertEqual(
            try ModelArtifactHasher().sha256(of: directory),
            "d785f6953ed84c82b2cccb5c079398afaddbabdd54888d837f2946836d99c2d2"
        )
    }

    private func makeFixture(
        priorityAgreement: Double = 0.90,
        commercialTrainingGranted: Bool = true,
        rubric: CoachRubricBinding = CoachAnnotationRubric.currentBinding,
        capturePlan: CapturePlanBinding = CapturePlanAssignment.currentPlan
    ) throws -> Fixture {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let modelURL = temporaryDirectory.appendingPathComponent("Synthetic.mlmodelc")
        try Data("synthetic model bytes".utf8).write(to: modelURL)
        let modelHash = try ModelArtifactHasher().sha256(of: modelURL)

        let evaluation = ModelReleaseEvaluationDocument(
            schemaVersion: ModelReleaseEvaluationDocument.currentSchemaVersion,
            modelIdentifier: "serveai.synthetic-validation-test",
            modelVersion: "1.0.0-test",
            modelSHA256: modelHash,
            rubric: rubric,
            capturePlan: capturePlan,
            releaseEligible: true,
            passesProductionAccuracyGates: true,
            commercialUseCleared: true,
            coachGroundTruthVerified: true,
            independentAdjudicationPolicyVerified: true,
            coreMLParityPassed: true,
            conversionParityMaximumAbsoluteError: 0.00001,
            conversionParitySampleCount: 60,
            design: ReleaseEvaluationDesign(
                heldOutClipCount: 60,
                uniquePlayerCount: 10,
                usesPlayerHeldOutSplit: true,
                allClipsHaveTrainingConsent: true,
                provenanceVerified: true,
                auditedSubgroupDimensions: EvaluationSubgroupDimension.allCases.map(\.rawValue),
                failedMaterialSubgroups: [],
                evaluatedCameraAngles: CameraAngle.allCases.map(\.rawValue),
                evaluatedSkillGroups: SkillLevel.allCases.map(\.rawValue),
                repeatabilityPairCount: 30,
                repeatabilityPlayerCount: 10,
                repeatabilityUsesExactSameVideo: true
            ),
            metrics: ReleaseEvaluationMetrics(
                qualityPrecision: 0.95,
                qualityRecall: 0.95,
                boundaryMeanAbsoluteErrorSeconds: 0.08,
                phaseVisibilityF1: 0.90,
                techniqueRatingMeanAbsoluteError: 0.40,
                priorityAgreement: priorityAgreement,
                repeatabilityWithinFivePoints: 0.95
            )
        )
        let evaluationURL = temporaryDirectory.appendingPathComponent("SyntheticEvaluation.json")
        try encoder.encode(evaluation).write(to: evaluationURL)

        let rights = ModelRightsEvidenceDocument(
            schemaVersion: 1,
            modelIdentifier: evaluation.modelIdentifier,
            modelVersion: evaluation.modelVersion,
            commercialUseCleared: true,
            trainingSources: [
                ModelTrainingSourceRights(
                    sourceIdentifier: "consented-first-party-test-data",
                    licenseIdentifier: "ServeAI-training-consent-v1",
                    evidenceSHA256: String(repeating: "a", count: 64),
                    permitsCommercialModelTraining: commercialTrainingGranted
                ),
            ]
        )
        let rightsURL = temporaryDirectory.appendingPathComponent("SyntheticRights.json")
        try encoder.encode(rights).write(to: rightsURL)

        let payload = ModelReleasePayload(
            schemaVersion: ModelReleasePayload.currentSchemaVersion,
            modelIdentifier: evaluation.modelIdentifier,
            modelVersion: evaluation.modelVersion,
            model: ModelReleaseResource(
                name: "Synthetic",
                fileExtension: "mlmodelc",
                sha256: modelHash
            ),
            evaluation: ModelReleaseResource(
                name: "SyntheticEvaluation",
                fileExtension: "json",
                sha256: try ModelArtifactHasher().sha256(of: evaluationURL)
            ),
            rightsEvidence: ModelReleaseResource(
                name: "SyntheticRights",
                fileExtension: "json",
                sha256: try ModelArtifactHasher().sha256(of: rightsURL)
            ),
            featureSchemaVersion: ServeModelFeatureSequence.schemaVersion,
            encoderIdentifier: ServeModelFeatureProvenance.encoderIdentifier,
            encoderVersion: ServeModelFeatureProvenance.encoderVersion,
            inputFeatureName: "features",
            inputFeatureCount: 1_467,
            outputFeatureNames: ["phaseVisibility", "boundaries", "techniqueVisibility", "ratings", "priority"],
            outputFeatureSizes: [
                "phaseVisibility": 10,
                "boundaries": 20,
                "techniqueVisibility": 6,
                "ratings": 6,
                "priority": 6,
            ],
            issuedAt: "2026-07-26T12:00:00Z"
        )
        let payloadData = try encoder.encode(payload)
        let privateKey = P256.Signing.PrivateKey()
        let publicKeyData = privateKey.publicKey.x963Representation
        let keyID = SHA256.hash(data: publicKeyData).map { String(format: "%02x", $0) }.joined()
        let signature = try privateKey.signature(for: payloadData)
        let envelope = SignedModelReleaseEnvelope(
            schemaVersion: 1,
            payloadBase64: payloadData.base64EncodedString(),
            signature: ModelReleaseSignature(
                algorithm: "P256-SHA256",
                keyID: keyID,
                derBase64: signature.derRepresentation.base64EncodedString()
            )
        )
        return Fixture(
            modelURL: modelURL,
            evaluationURL: evaluationURL,
            rightsURL: rightsURL,
            envelopeData: try encoder.encode(envelope),
            verifier: ValidatedModelReleaseVerifier(
                pinnedPublicKeysX963: [keyID: publicKeyData]
            )
        )
    }
}

private struct Fixture {
    let modelURL: URL
    let evaluationURL: URL
    let rightsURL: URL
    let envelopeData: Data
    let verifier: ValidatedModelReleaseVerifier
}
