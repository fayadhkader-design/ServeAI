import Foundation
import XCTest
@testable import ServeAI

final class EvaluationCandidateTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var modelURL: URL!
    private var parityURL: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        modelURL = temporaryDirectory.appendingPathComponent("Candidate.mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(at: modelURL, withIntermediateDirectories: true)
        try Data("exact compiled candidate".utf8).write(
            to: modelURL.appendingPathComponent("model.bin")
        )
        parityURL = temporaryDirectory.appendingPathComponent("CandidateParity.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testVerifierAcceptsExactEvaluationOnlyCandidate() throws {
        let inputs = try makeInputs()

        let verified = try EvaluationCandidateVerifier().verify(
            manifestData: inputs.manifestData,
            modelURL: modelURL,
            parityURL: parityURL
        )

        XCTAssertEqual(verified.manifest.modelIdentifier, "serveai.coach-temporal")
        XCTAssertEqual(verified.manifest.purpose, "release-evaluation-only")
        XCTAssertEqual(verified.manifest.model.sha256, try ModelArtifactHasher().sha256(of: modelURL))
    }

    func testVerifierRejectsCompiledModelTampering() throws {
        let inputs = try makeInputs()
        try Data("tampered".utf8).write(to: modelURL.appendingPathComponent("model.bin"))

        XCTAssertThrowsError(try EvaluationCandidateVerifier().verify(
            manifestData: inputs.manifestData,
            modelURL: modelURL,
            parityURL: parityURL
        )) { error in
            XCTAssertEqual(
                error as? EvaluationCandidateVerificationError,
                .artifactDigestMismatch("model")
            )
        }
    }

    func testVerifierRejectsManifestThatClaimsAnotherPurpose() throws {
        let inputs = try makeInputs(purpose: "production-release")

        XCTAssertThrowsError(try EvaluationCandidateVerifier().verify(
            manifestData: inputs.manifestData,
            modelURL: modelURL,
            parityURL: parityURL
        )) { error in
            XCTAssertEqual(error as? EvaluationCandidateVerificationError, .invalidPurpose)
        }
    }

    func testVerifierRejectsParityBelowHeldOutMinimum() throws {
        let inputs = try makeInputs(sampleCount: 59)

        XCTAssertThrowsError(try EvaluationCandidateVerifier().verify(
            manifestData: inputs.manifestData,
            modelURL: modelURL,
            parityURL: parityURL
        )) { error in
            XCTAssertEqual(error as? EvaluationCandidateVerificationError, .invalidParityEvidence)
        }
    }

    private func makeInputs(
        purpose: String = EvaluationCandidateManifest.evaluationPurpose,
        sampleCount: Int = 60
    ) throws -> (manifestData: Data, manifest: EvaluationCandidateManifest) {
        let modelHash = try ModelArtifactHasher().sha256(of: modelURL)
        let parity = EvaluationCandidateParityDocument(
            schemaVersion: 2,
            modelIdentifier: "serveai.coach-temporal",
            modelVersion: "1.0.0-rc1",
            compiledModelSHA256: modelHash,
            sampleCount: sampleCount,
            maximumAbsoluteError: 0.00001,
            maximumAbsoluteErrorByOutput: Dictionary(
                uniqueKeysWithValues: EvaluationCandidateVerifier.requiredOutputSizes.keys.map {
                    ($0, 0.00001)
                }
            ),
            tolerance: 0.0001,
            passes: true,
            releaseEligible: false
        )
        try JSONEncoder().encode(parity).write(to: parityURL)
        let manifest = EvaluationCandidateManifest(
            schemaVersion: 1,
            purpose: purpose,
            modelIdentifier: parity.modelIdentifier,
            modelVersion: parity.modelVersion,
            model: ModelReleaseResource(
                name: "Candidate",
                fileExtension: "mlmodelc",
                sha256: modelHash
            ),
            coreMLParity: ModelReleaseResource(
                name: "CandidateParity",
                fileExtension: "json",
                sha256: try ModelArtifactHasher().sha256(of: parityURL)
            ),
            featureSchemaVersion: ServeModelFeatureSequence.schemaVersion,
            encoderIdentifier: ServeModelFeatureProvenance.encoderIdentifier,
            encoderVersion: ServeModelFeatureProvenance.encoderVersion,
            inputFeatureName: "features",
            inputFeatureCount: 1_467,
            outputFeatureNames: Array(EvaluationCandidateVerifier.requiredOutputSizes.keys),
            outputFeatureSizes: EvaluationCandidateVerifier.requiredOutputSizes
        )
        return (try JSONEncoder().encode(manifest), manifest)
    }
}
