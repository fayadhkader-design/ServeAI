import CryptoKit
import Foundation

struct ModelReleaseResource: Codable, Equatable, Sendable {
    let name: String
    let fileExtension: String
    let sha256: String

    var isSafeBundleResource: Bool {
        !name.isEmpty
            && !fileExtension.isEmpty
            && !name.contains("/")
            && !name.contains("\\")
            && !fileExtension.contains("/")
            && !fileExtension.contains("\\")
            && sha256.isLowercaseSHA256
    }
}

struct ModelReleasePayload: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let modelIdentifier: String
    let modelVersion: String
    let model: ModelReleaseResource
    let evaluation: ModelReleaseResource
    let rightsEvidence: ModelReleaseResource
    let featureSchemaVersion: Int
    let encoderIdentifier: String
    let encoderVersion: String
    let inputFeatureName: String
    let inputFeatureCount: Int
    let outputFeatureNames: [String]
    let outputFeatureSizes: [String: Int]
    let issuedAt: String
}

struct ModelReleaseSignature: Codable, Equatable, Sendable {
    let algorithm: String
    let keyID: String
    let derBase64: String
}

struct SignedModelReleaseEnvelope: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let payloadBase64: String
    let signature: ModelReleaseSignature
}

struct ReleaseEvaluationMetrics: Codable, Equatable, Sendable {
    let qualityPrecision: Double
    let qualityRecall: Double
    let boundaryMeanAbsoluteErrorSeconds: Double
    let phaseVisibilityF1: Double
    let techniqueRatingMeanAbsoluteError: Double
    let priorityAgreement: Double
    let repeatabilityWithinFivePoints: Double
}

struct ReleaseEvaluationDesign: Codable, Equatable, Sendable {
    let heldOutClipCount: Int
    let uniquePlayerCount: Int
    let usesPlayerHeldOutSplit: Bool
    let allClipsHaveTrainingConsent: Bool
    let provenanceVerified: Bool
    let auditedSubgroupDimensions: [String]
    let failedMaterialSubgroups: [String]
    let evaluatedCameraAngles: [String]
    let evaluatedSkillGroups: [String]
    let repeatabilityPairCount: Int
    let repeatabilityPlayerCount: Int
    let repeatabilityUsesExactSameVideo: Bool
}

struct ModelReleaseEvaluationDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 4

    let schemaVersion: Int
    let modelIdentifier: String
    let modelVersion: String
    let modelSHA256: String
    let rubric: CoachRubricBinding
    let capturePlan: CapturePlanBinding
    let releaseEligible: Bool
    let passesProductionAccuracyGates: Bool
    let commercialUseCleared: Bool
    let coachGroundTruthVerified: Bool
    let independentAdjudicationPolicyVerified: Bool
    let coreMLParityPassed: Bool
    let conversionParityMaximumAbsoluteError: Double
    let conversionParitySampleCount: Int
    let design: ReleaseEvaluationDesign
    let metrics: ReleaseEvaluationMetrics

    func failedCriteria(
        _ criteria: AccuracyAcceptanceCriteria = AccuracyAcceptanceCriteria()
    ) -> [String] {
        var failures: [String] = []
        if schemaVersion != Self.currentSchemaVersion { failures.append("evaluation schema") }
        if rubric != CoachAnnotationRubric.currentBinding { failures.append("coach rubric") }
        if capturePlan != CapturePlanAssignment.currentPlan { failures.append("capture plan") }
        if !releaseEligible { failures.append("release eligibility") }
        if !passesProductionAccuracyGates { failures.append("declared production gates") }
        if !commercialUseCleared { failures.append("commercial-use clearance") }
        if !coachGroundTruthVerified { failures.append("coach ground truth") }
        if !independentAdjudicationPolicyVerified { failures.append("independent adjudication") }
        if !coreMLParityPassed { failures.append("Core ML parity") }
        if !conversionParityMaximumAbsoluteError.isFinite
            || conversionParityMaximumAbsoluteError > 0.0001 {
            failures.append("Core ML parity error")
        }
        if conversionParitySampleCount < criteria.minimumHeldOutClipCount {
            failures.append("Core ML parity sample count")
        }
        if design.heldOutClipCount < criteria.minimumHeldOutClipCount {
            failures.append("held-out clip count")
        }
        if design.uniquePlayerCount < criteria.minimumHeldOutPlayerCount {
            failures.append("held-out player count")
        }
        if !design.usesPlayerHeldOutSplit { failures.append("player-held-out split") }
        if !design.allClipsHaveTrainingConsent { failures.append("training consent verification") }
        if !design.provenanceVerified { failures.append("dataset provenance verification") }

        let audited = Set(design.auditedSubgroupDimensions)
        let requiredDimensions = Set(EvaluationSubgroupDimension.allCases.map(\.rawValue))
        if !requiredDimensions.isSubset(of: audited) { failures.append("subgroup coverage") }
        if !design.failedMaterialSubgroups.isEmpty { failures.append("subgroup performance") }
        if !Set(CameraAngle.allCases.map(\.rawValue)).isSubset(of: Set(design.evaluatedCameraAngles)) {
            failures.append("camera-angle coverage")
        }
        if !Set(SkillLevel.allCases.map(\.rawValue)).isSubset(of: Set(design.evaluatedSkillGroups)) {
            failures.append("skill-group coverage")
        }
        if design.repeatabilityPairCount < 30 {
            failures.append("repeatability pair count")
        }
        if design.repeatabilityPlayerCount < criteria.minimumHeldOutPlayerCount {
            failures.append("repeatability player count")
        }
        if !design.repeatabilityUsesExactSameVideo {
            failures.append("repeatability source binding")
        }

        let finiteMetrics = [
            metrics.qualityPrecision,
            metrics.qualityRecall,
            metrics.boundaryMeanAbsoluteErrorSeconds,
            metrics.phaseVisibilityF1,
            metrics.techniqueRatingMeanAbsoluteError,
            metrics.priorityAgreement,
            metrics.repeatabilityWithinFivePoints,
        ].allSatisfy(\.isFinite)
        if !finiteMetrics { failures.append("finite evaluation metrics") }
        if metrics.qualityPrecision < criteria.minimumQualityPrecision {
            failures.append("recording-quality precision")
        }
        if metrics.qualityRecall < criteria.minimumQualityRecall {
            failures.append("recording-quality recall")
        }
        if metrics.boundaryMeanAbsoluteErrorSeconds > criteria.maximumBoundaryMeanAbsoluteError {
            failures.append("phase-boundary timing")
        }
        if metrics.phaseVisibilityF1 < criteria.minimumPhaseVisibilityF1 {
            failures.append("phase visibility")
        }
        if metrics.techniqueRatingMeanAbsoluteError > criteria.maximumTechniqueRatingMeanAbsoluteError {
            failures.append("technique rating agreement")
        }
        if metrics.priorityAgreement < criteria.minimumPriorityAgreement {
            failures.append("coach priority agreement")
        }
        if metrics.repeatabilityWithinFivePoints < criteria.minimumRepeatabilityWithinFivePoints {
            failures.append("repeatability")
        }
        return failures
    }
}

struct ModelTrainingSourceRights: Codable, Equatable, Sendable {
    let sourceIdentifier: String
    let licenseIdentifier: String
    let evidenceSHA256: String
    let permitsCommercialModelTraining: Bool

    var isCleared: Bool {
        !sourceIdentifier.isEmpty
            && !licenseIdentifier.isEmpty
            && evidenceSHA256.isLowercaseSHA256
            && permitsCommercialModelTraining
    }
}

struct ModelRightsEvidenceDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let modelIdentifier: String
    let modelVersion: String
    let commercialUseCleared: Bool
    let trainingSources: [ModelTrainingSourceRights]

    var isCleared: Bool {
        schemaVersion == Self.currentSchemaVersion
            && commercialUseCleared
            && !trainingSources.isEmpty
            && trainingSources.allSatisfy(\.isCleared)
    }
}

struct VerifiedModelRelease: Sendable {
    let payload: ModelReleasePayload
    let evaluation: ModelReleaseEvaluationDocument
    let modelURL: URL
}

enum ModelReleaseVerificationError: LocalizedError, Equatable {
    case malformedEnvelope
    case unsupportedSchema
    case unsafeResource
    case unsupportedSignature
    case unknownSigningKey
    case invalidSigningKey
    case invalidSignature
    case artifactDigestMismatch(String)
    case identityMismatch
    case incompatibleFeatureContract
    case failedReleaseGates([String])

    var errorDescription: String? {
        switch self {
        case .malformedEnvelope: "the signed release envelope is malformed"
        case .unsupportedSchema: "the release schema is unsupported"
        case .unsafeResource: "the release references an unsafe bundle resource"
        case .unsupportedSignature: "the release signature algorithm is unsupported"
        case .unknownSigningKey: "the release was not signed by a pinned ServeAI authority"
        case .invalidSigningKey: "the pinned release authority key is invalid"
        case .invalidSignature: "the release signature is invalid"
        case .artifactDigestMismatch(let artifact): "the \(artifact) checksum does not match the signed release"
        case .identityMismatch: "the evaluation and model identities do not match"
        case .incompatibleFeatureContract: "the model feature contract is incompatible with this app"
        case .failedReleaseGates(let failures): "release gates failed: \(failures.joined(separator: ", "))"
        }
    }
}

struct ModelArtifactHasher: Sendable {
    func sha256(of url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        if values.isRegularFile == true {
            return try digestFile(url)
        }
        guard values.isDirectory == true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let keys: Set<URLResourceKey> = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            throw CocoaError(.fileReadUnknown)
        }
        let files = enumerator.compactMap { $0 as? URL }.filter {
            (try? $0.resourceValues(forKeys: keys).isRegularFile) == true
        }.sorted {
            relativePath(of: $0, under: url) < relativePath(of: $1, under: url)
        }
        var treeHasher = SHA256()
        treeHasher.update(data: Data("serveai-artifact-tree-v1\n".utf8))
        for file in files {
            let path = relativePath(of: file, under: url)
            guard !path.contains("\n") else { throw CocoaError(.fileReadCorruptFile) }
            let fileDigest = try digestFile(file)
            treeHasher.update(data: Data("\(path)\t\(fileDigest)\n".utf8))
        }
        return treeHasher.finalize().hexString
    }

    private func digestFile(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().hexString
    }

    private func relativePath(of child: URL, under root: URL) -> String {
        String(child.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
    }
}

struct ValidatedModelReleaseVerifier: Sendable {
    /// Keys are indexed by SHA-256 of their ANSI X9.63 P-256 representation.
    let pinnedPublicKeysX963: [String: Data]
    let artifactHasher: ModelArtifactHasher

    init(
        pinnedPublicKeysX963: [String: Data],
        artifactHasher: ModelArtifactHasher = ModelArtifactHasher()
    ) {
        self.pinnedPublicKeysX963 = pinnedPublicKeysX963
        self.artifactHasher = artifactHasher
    }

    func verify(
        envelopeData: Data,
        modelURL: URL,
        evaluationURL: URL,
        rightsEvidenceURL: URL
    ) throws -> VerifiedModelRelease {
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(SignedModelReleaseEnvelope.self, from: envelopeData),
              let payloadData = Data(base64Encoded: envelope.payloadBase64),
              let payload = try? decoder.decode(ModelReleasePayload.self, from: payloadData),
              let signatureData = Data(base64Encoded: envelope.signature.derBase64) else {
            throw ModelReleaseVerificationError.malformedEnvelope
        }
        guard envelope.schemaVersion == SignedModelReleaseEnvelope.currentSchemaVersion,
              payload.schemaVersion == ModelReleasePayload.currentSchemaVersion else {
            throw ModelReleaseVerificationError.unsupportedSchema
        }
        guard payload.model.isSafeBundleResource,
              payload.evaluation.isSafeBundleResource,
              payload.rightsEvidence.isSafeBundleResource else {
            throw ModelReleaseVerificationError.unsafeResource
        }
        guard envelope.signature.algorithm == "P256-SHA256",
              envelope.signature.keyID.isLowercaseSHA256 else {
            throw ModelReleaseVerificationError.unsupportedSignature
        }
        guard let publicKeyData = pinnedPublicKeysX963[envelope.signature.keyID] else {
            throw ModelReleaseVerificationError.unknownSigningKey
        }
        guard SHA256.hash(data: publicKeyData).hexString == envelope.signature.keyID,
              let publicKey = try? P256.Signing.PublicKey(x963Representation: publicKeyData) else {
            throw ModelReleaseVerificationError.invalidSigningKey
        }
        guard let signature = try? P256.Signing.ECDSASignature(derRepresentation: signatureData),
              publicKey.isValidSignature(signature, for: payloadData) else {
            throw ModelReleaseVerificationError.invalidSignature
        }

        guard try artifactHasher.sha256(of: modelURL) == payload.model.sha256 else {
            throw ModelReleaseVerificationError.artifactDigestMismatch("model")
        }
        guard try artifactHasher.sha256(of: evaluationURL) == payload.evaluation.sha256 else {
            throw ModelReleaseVerificationError.artifactDigestMismatch("evaluation")
        }
        guard try artifactHasher.sha256(of: rightsEvidenceURL) == payload.rightsEvidence.sha256 else {
            throw ModelReleaseVerificationError.artifactDigestMismatch("rights evidence")
        }
        let evaluationData = try Data(contentsOf: evaluationURL)
        guard let evaluation = try? decoder.decode(ModelReleaseEvaluationDocument.self, from: evaluationData) else {
            throw ModelReleaseVerificationError.malformedEnvelope
        }
        let rightsData = try Data(contentsOf: rightsEvidenceURL)
        guard let rights = try? decoder.decode(ModelRightsEvidenceDocument.self, from: rightsData),
              rights.isCleared else {
            throw ModelReleaseVerificationError.failedReleaseGates(["commercial-use rights evidence"])
        }
        guard evaluation.modelIdentifier == payload.modelIdentifier,
              evaluation.modelVersion == payload.modelVersion,
              evaluation.modelSHA256 == payload.model.sha256,
              rights.modelIdentifier == payload.modelIdentifier,
              rights.modelVersion == payload.modelVersion else {
            throw ModelReleaseVerificationError.identityMismatch
        }
        let requiredOutputs = Set(["phaseVisibility", "boundaries", "techniqueVisibility", "ratings", "priority"])
        let requiredOutputSizes = [
            "phaseVisibility": 10,
            "boundaries": 20,
            "techniqueVisibility": 6,
            "ratings": 6,
            "priority": 6,
        ]
        guard payload.featureSchemaVersion == ServeModelFeatureSequence.schemaVersion,
              payload.encoderIdentifier == ServeModelFeatureProvenance.encoderIdentifier,
              payload.encoderVersion == ServeModelFeatureProvenance.encoderVersion,
              payload.inputFeatureName == "features",
              payload.inputFeatureCount == 1_467,
              Set(payload.outputFeatureNames) == requiredOutputs,
              payload.outputFeatureSizes == requiredOutputSizes,
              ISO8601DateFormatter().date(from: payload.issuedAt) != nil else {
            throw ModelReleaseVerificationError.incompatibleFeatureContract
        }
        let failures = evaluation.failedCriteria()
        guard failures.isEmpty else {
            throw ModelReleaseVerificationError.failedReleaseGates(failures)
        }
        return VerifiedModelRelease(
            payload: payload,
            evaluation: evaluation,
            modelURL: modelURL
        )
    }
}

struct BundledValidatedModelReleaseLoader: Sendable {
    static let envelopeResourceName = "ServeAIValidatedModelRelease"

    /// Production signing keys are intentionally empty until an offline authority is provisioned.
    /// A validated model cannot run merely because a manifest is placed in the bundle.
    static let productionPinnedPublicKeysX963: [String: Data] = [:]

    let bundle: Bundle
    let verifier: ValidatedModelReleaseVerifier

    init(
        bundle: Bundle = .main,
        pinnedPublicKeysX963: [String: Data] = Self.productionPinnedPublicKeysX963
    ) {
        self.bundle = bundle
        verifier = ValidatedModelReleaseVerifier(pinnedPublicKeysX963: pinnedPublicKeysX963)
    }

    func load() throws -> VerifiedModelRelease {
        guard let envelopeURL = bundle.url(
            forResource: Self.envelopeResourceName,
            withExtension: "json"
        ) else {
            throw ServeAIError.modelUnavailable("signed validated-model release envelope is missing")
        }
        let envelopeData = try Data(contentsOf: envelopeURL)
        guard let envelope = try? JSONDecoder().decode(SignedModelReleaseEnvelope.self, from: envelopeData),
              let payloadData = Data(base64Encoded: envelope.payloadBase64),
              let payload = try? JSONDecoder().decode(ModelReleasePayload.self, from: payloadData),
              payload.model.isSafeBundleResource,
              payload.evaluation.isSafeBundleResource,
              payload.rightsEvidence.isSafeBundleResource else {
            throw ServeAIError.modelUnavailable("signed validated-model release envelope is malformed")
        }
        guard let modelURL = bundle.url(forResource: payload.model.name, withExtension: payload.model.fileExtension),
              let evaluationURL = bundle.url(forResource: payload.evaluation.name, withExtension: payload.evaluation.fileExtension),
              let rightsURL = bundle.url(forResource: payload.rightsEvidence.name, withExtension: payload.rightsEvidence.fileExtension) else {
            throw ServeAIError.modelUnavailable("one or more signed validated-model artifacts are missing")
        }
        do {
            return try verifier.verify(
                envelopeData: envelopeData,
                modelURL: modelURL,
                evaluationURL: evaluationURL,
                rightsEvidenceURL: rightsURL
            )
        } catch {
            throw ServeAIError.modelUnavailable(error.localizedDescription)
        }
    }
}

private extension String {
    var isLowercaseSHA256: Bool {
        count == 64 && allSatisfy { "0123456789abcdef".contains($0) }
    }
}

private extension Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
