import Foundation

struct EvaluationCandidateManifest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let evaluationPurpose = "release-evaluation-only"

    let schemaVersion: Int
    let purpose: String
    let modelIdentifier: String
    let modelVersion: String
    let model: ModelReleaseResource
    let coreMLParity: ModelReleaseResource
    let featureSchemaVersion: Int
    let encoderIdentifier: String
    let encoderVersion: String
    let inputFeatureName: String
    let inputFeatureCount: Int
    let outputFeatureNames: [String]
    let outputFeatureSizes: [String: Int]
}

struct EvaluationCandidateParityDocument: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let modelIdentifier: String
    let modelVersion: String
    let compiledModelSHA256: String
    let sampleCount: Int
    let maximumAbsoluteError: Double
    let maximumAbsoluteErrorByOutput: [String: Double]
    let tolerance: Double
    let passes: Bool
    let releaseEligible: Bool
}

struct VerifiedEvaluationCandidate: Sendable {
    let manifest: EvaluationCandidateManifest
    let modelURL: URL
}

enum EvaluationCandidateVerificationError: LocalizedError, Equatable {
    case malformedManifest
    case unsupportedSchema
    case invalidPurpose
    case unsafeResource
    case incompatibleFeatureContract
    case artifactDigestMismatch(String)
    case invalidParityEvidence
    case identityMismatch

    var errorDescription: String? {
        switch self {
        case .malformedManifest: "the evaluation-candidate manifest is malformed"
        case .unsupportedSchema: "the evaluation-candidate schema is unsupported"
        case .invalidPurpose: "the manifest is not restricted to release evaluation"
        case .unsafeResource: "the manifest references an unsafe bundle resource"
        case .incompatibleFeatureContract: "the candidate feature contract is incompatible with this app"
        case .artifactDigestMismatch(let artifact): "the evaluation-candidate \(artifact) checksum does not match"
        case .invalidParityEvidence: "the candidate lacks passing compiled Core ML parity evidence"
        case .identityMismatch: "the candidate model and parity identities do not match"
        }
    }
}

struct EvaluationCandidateVerifier: Sendable {
    static let requiredOutputSizes = [
        "phaseVisibility": 10,
        "boundaries": 20,
        "techniqueVisibility": 6,
        "ratings": 6,
        "priority": 6,
    ]

    let artifactHasher: ModelArtifactHasher

    init(artifactHasher: ModelArtifactHasher = ModelArtifactHasher()) {
        self.artifactHasher = artifactHasher
    }

    func verify(
        manifestData: Data,
        modelURL: URL,
        parityURL: URL
    ) throws -> VerifiedEvaluationCandidate {
        let decoder = JSONDecoder()
        guard let manifest = try? decoder.decode(EvaluationCandidateManifest.self, from: manifestData) else {
            throw EvaluationCandidateVerificationError.malformedManifest
        }
        guard manifest.schemaVersion == EvaluationCandidateManifest.currentSchemaVersion else {
            throw EvaluationCandidateVerificationError.unsupportedSchema
        }
        guard manifest.purpose == EvaluationCandidateManifest.evaluationPurpose else {
            throw EvaluationCandidateVerificationError.invalidPurpose
        }
        guard manifest.model.isSafeBundleResource,
              manifest.coreMLParity.isSafeBundleResource else {
            throw EvaluationCandidateVerificationError.unsafeResource
        }
        guard !manifest.modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !manifest.modelVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              manifest.featureSchemaVersion == ServeModelFeatureSequence.schemaVersion,
              manifest.encoderIdentifier == ServeModelFeatureProvenance.encoderIdentifier,
              manifest.encoderVersion == ServeModelFeatureProvenance.encoderVersion,
              manifest.inputFeatureName == "features",
              manifest.inputFeatureCount == 1_467,
              Set(manifest.outputFeatureNames) == Set(Self.requiredOutputSizes.keys),
              manifest.outputFeatureSizes == Self.requiredOutputSizes else {
            throw EvaluationCandidateVerificationError.incompatibleFeatureContract
        }
        guard try artifactHasher.sha256(of: modelURL) == manifest.model.sha256 else {
            throw EvaluationCandidateVerificationError.artifactDigestMismatch("model")
        }
        guard try artifactHasher.sha256(of: parityURL) == manifest.coreMLParity.sha256 else {
            throw EvaluationCandidateVerificationError.artifactDigestMismatch("parity report")
        }
        guard let parity = try? decoder.decode(
            EvaluationCandidateParityDocument.self,
            from: Data(contentsOf: parityURL)
        ) else {
            throw EvaluationCandidateVerificationError.invalidParityEvidence
        }
        guard parity.modelIdentifier == manifest.modelIdentifier,
              parity.modelVersion == manifest.modelVersion,
              parity.compiledModelSHA256 == manifest.model.sha256 else {
            throw EvaluationCandidateVerificationError.identityMismatch
        }
        let requiredOutputs = Set(Self.requiredOutputSizes.keys)
        guard parity.schemaVersion == 2,
              parity.passes,
              !parity.releaseEligible,
              parity.sampleCount >= 60,
              parity.maximumAbsoluteError.isFinite,
              parity.maximumAbsoluteError <= 0.0001,
              parity.tolerance.isFinite,
              parity.tolerance == 0.0001,
              Set(parity.maximumAbsoluteErrorByOutput.keys) == requiredOutputs,
              parity.maximumAbsoluteErrorByOutput.values.allSatisfy({ $0.isFinite && $0 <= 0.0001 }) else {
            throw EvaluationCandidateVerificationError.invalidParityEvidence
        }
        return VerifiedEvaluationCandidate(manifest: manifest, modelURL: modelURL)
    }
}

struct BundledEvaluationCandidateLoader: Sendable {
    static let manifestResourceName = "ServeAIEvaluationCandidate"

    let bundle: Bundle
    let verifier: EvaluationCandidateVerifier

    init(
        bundle: Bundle = .main,
        verifier: EvaluationCandidateVerifier = EvaluationCandidateVerifier()
    ) {
        self.bundle = bundle
        self.verifier = verifier
    }

    func load() throws -> VerifiedEvaluationCandidate {
        guard let manifestURL = bundle.url(
            forResource: Self.manifestResourceName,
            withExtension: "json"
        ) else {
            throw ServeAIError.modelUnavailable("evaluation-candidate manifest is missing")
        }
        let manifestData = try Data(contentsOf: manifestURL)
        guard let manifest = try? JSONDecoder().decode(EvaluationCandidateManifest.self, from: manifestData),
              manifest.model.isSafeBundleResource,
              manifest.coreMLParity.isSafeBundleResource else {
            throw ServeAIError.modelUnavailable("evaluation-candidate manifest is malformed")
        }
        guard let modelURL = bundle.url(
            forResource: manifest.model.name,
            withExtension: manifest.model.fileExtension
        ), let parityURL = bundle.url(
            forResource: manifest.coreMLParity.name,
            withExtension: manifest.coreMLParity.fileExtension
        ) else {
            throw ServeAIError.modelUnavailable("evaluation-candidate artifacts are missing")
        }
        do {
            return try verifier.verify(
                manifestData: manifestData,
                modelURL: modelURL,
                parityURL: parityURL
            )
        } catch {
            throw ServeAIError.modelUnavailable(error.localizedDescription)
        }
    }
}

struct BundledEvaluationCandidateServeInferenceModel: ServeInferenceModel {
    let identifier = "serveai.evaluation-candidate"
    let version = "manifest-bundle"
    private let loader: BundledEvaluationCandidateLoader

    init(loader: BundledEvaluationCandidateLoader = BundledEvaluationCandidateLoader()) {
        self.loader = loader
    }

    func predict(
        features: ServeModelFeatureSequence,
        skillLevel: SkillLevel
    ) async throws -> ServeTechniqueModelPrediction {
        let candidate = try await Task.detached(priority: .userInitiated) {
            try loader.load()
        }.value
        return try await BundledExperimentalServeInferenceModel(
            verifiedEvaluationCandidate: candidate
        ).predict(features: features, skillLevel: skillLevel)
    }
}
