import CoreML
import Foundation

struct BundledExperimentalServeInferenceModel: ServeInferenceModel {
    private enum DeploymentStatus: Sendable {
        case pseudoCoachExperiment
        case evaluationCandidate
        case validatedRelease

        var isValidated: Bool { self == .validatedRelease }
    }

    let identifier: String
    let version: String
    private let modelURL: URL?
    private let deploymentStatus: DeploymentStatus
    private let modelArtifactSHA256: String?

    init(bundle: Bundle = .main) {
        identifier = "serveai.thetis-pseudo-coach"
        version = "0.2.0-research"
        modelURL = bundle.url(forResource: "ServeAITennisPseudoCoach", withExtension: "mlmodelc")
        deploymentStatus = .pseudoCoachExperiment
        modelArtifactSHA256 = modelURL.flatMap { try? ModelArtifactHasher().sha256(of: $0) }
    }

    init(verifiedEvaluationCandidate: VerifiedEvaluationCandidate) {
        identifier = verifiedEvaluationCandidate.manifest.modelIdentifier
        version = verifiedEvaluationCandidate.manifest.modelVersion
        modelURL = verifiedEvaluationCandidate.modelURL
        deploymentStatus = .evaluationCandidate
        modelArtifactSHA256 = verifiedEvaluationCandidate.manifest.model.sha256
    }

    init(verifiedRelease: VerifiedModelRelease) {
        identifier = verifiedRelease.payload.modelIdentifier
        version = verifiedRelease.payload.modelVersion
        modelURL = verifiedRelease.modelURL
        deploymentStatus = .validatedRelease
        modelArtifactSHA256 = verifiedRelease.payload.model.sha256
    }

    private let phases: [ServePhaseKind] = [
        .startingStance, .ballToss, .loading, .trophyPosition, .legDrive,
        .racketDrop, .upwardAcceleration, .contactPosition, .pronation, .landingFollowThrough,
    ]
    private let techniques: [CoachTechniqueLabel] = [
        .tossPlacement, .loadingSequence, .trophyAlignment,
        .legDriveTiming, .contactReach, .landingBalance,
    ]

    func predict(
        features: ServeModelFeatureSequence,
        skillLevel _: SkillLevel
    ) async throws -> ServeTechniqueModelPrediction {
        let vector = try featureVector(features)
        let outputs = try await Task.detached(priority: .userInitiated) {
            try runModel(vector: vector)
        }.value
        let visibility = try values(named: "phaseVisibility", from: outputs)
        let boundaries = try values(named: "boundaries", from: outputs)
        let techniqueVisibility = try values(named: "techniqueVisibility", from: outputs)
        let ratings = try values(named: "ratings", from: outputs)
        let priorityScores = try values(named: "priority", from: outputs)

        let detectedPhases = phases.enumerated().compactMap { index, phase -> DetectedServePhase? in
            guard index < visibility.count,
                  index * 2 + 1 < boundaries.count,
                  phase != .racketDrop,
                  phase != .pronation,
                  visibility[index] >= 0.5 else { return nil }
            let start = clamp(boundaries[index * 2], lower: 0, upper: 1)
            let end = max(start, clamp(boundaries[index * 2 + 1], lower: 0, upper: 1))
            return DetectedServePhase(
                phase: phase,
                startTime: start * features.duration,
                endTime: end * features.duration,
                confidence: clamp(visibility[index], lower: 0, upper: 1)
            )
        }

        let phaseScores = phases.map { phase in
            guard let technique = technique(for: phase),
                  let index = techniques.firstIndex(of: technique),
                  index < techniqueVisibility.count,
                  index < ratings.count,
                  techniqueVisibility[index] >= 0.5 else {
                return PhaseScore(
                    phase: phase,
                    score: nil,
                    confidence: .low,
                    note: unavailableNote(for: phase)
                )
            }
            let normalized = clamp(ratings[index], lower: 0, upper: 1)
            return PhaseScore(
                phase: phase,
                score: Int((20 + normalized * 80).rounded()),
                confidence: .low,
                note: phaseScoreNote
            )
        }

        let technicalMetrics = techniques.enumerated().compactMap { index, technique -> TechnicalMetric? in
            guard index < techniqueVisibility.count,
                  index < ratings.count,
                  techniqueVisibility[index] >= 0.5,
                  let phase = phase(for: technique) else { return nil }
            let rating = 1 + clamp(ratings[index], lower: 0, upper: 1) * 4
            return TechnicalMetric(
                title: technique.title,
                value: String(format: "%.1f / 5", rating),
                context: technicalMetricContext,
                confidence: .low,
                relatedPhase: phase
            )
        }
        let coachingPriority = techniques.indices
            .filter { index in
                index < techniqueVisibility.count
                    && index < priorityScores.count
                    && techniqueVisibility[index] >= 0.5
                    && phase(for: techniques[index]).flatMap { phase in
                        phaseScores.first(where: { $0.phase == phase })?.score
                    } != nil
            }
            .max { priorityScores[$0] < priorityScores[$1] }
            .map { techniques[$0] }

        return ServeTechniqueModelPrediction(
            modelIdentifier: identifier,
            modelVersion: version,
            modelArtifactSHA256: modelArtifactSHA256,
            validatedReleaseVerified: deploymentStatus.isValidated,
            detectedPhases: detectedPhases,
            phaseScores: phaseScores,
            technicalMetrics: technicalMetrics,
            coachingPriority: coachingPriority
        )
    }

    private func runModel(vector: [Double]) throws -> MLFeatureProvider {
        guard let modelURL else {
            throw ServeAIError.modelUnavailable(
                deploymentStatus.isValidated
                    ? "signed validated Core ML model is missing from the app bundle"
                    : "unvalidated Core ML model is missing from the app bundle"
            )
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let model = try MLModel(contentsOf: modelURL, configuration: configuration)
        let input = try MLMultiArray(shape: [NSNumber(value: vector.count)], dataType: .float32)
        for (index, value) in vector.enumerated() {
            input[index] = NSNumber(value: Float(value))
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "features": MLFeatureValue(multiArray: input),
        ])
        return try model.prediction(from: provider)
    }

    private func values(named name: String, from provider: MLFeatureProvider) throws -> [Double] {
        guard let array = provider.featureValue(for: name)?.multiArrayValue else {
            throw ServeAIError.modelUnavailable("model output \(name) is missing")
        }
        return (0..<array.count).map { array[$0].doubleValue }
    }

    private func featureVector(_ sequence: ServeModelFeatureSequence) throws -> [Double] {
        guard sequence.schemaVersion == ServeModelFeatureSequence.schemaVersion,
              sequence.frames.count >= 18,
              let first = sequence.frames.first?.timestamp,
              let last = sequence.frames.last?.timestamp,
              last > first else {
            throw ServeAIError.poseTrackingFailed
        }
        let matrices = sequence.frames.map(frameValues)
        let targetCount = 24
        let targets = (0..<targetCount).map { index in
            first + (last - first) * Double(index) / Double(targetCount - 1)
        }
        var vector = [
            min(sequence.duration, 45) / 45,
            sequence.cameraAngle == .side ? 1.0 : 0.0,
            sequence.cameraAngle == .rear ? 1.0 : 0.0,
        ]
        for target in targets {
            let upper = sequence.frames.firstIndex { $0.timestamp >= target } ?? (sequence.frames.count - 1)
            let lower = max(0, upper - 1)
            let lowerTime = sequence.frames[lower].timestamp
            let upperTime = sequence.frames[upper].timestamp
            let fraction = upperTime > lowerTime ? (target - lowerTime) / (upperTime - lowerTime) : 0
            for column in matrices[lower].indices {
                vector.append(matrices[lower][column] + (matrices[upper][column] - matrices[lower][column]) * fraction)
            }
        }
        guard vector.count == 1_467 else {
            throw ServeAIError.modelUnavailable("feature contract produced \(vector.count) values")
        }
        return vector
    }

    private func frameValues(_ frame: ServeModelFrameFeature) -> [Double] {
        let byJoint = Dictionary(uniqueKeysWithValues: frame.joints.map { ($0.joint, $0) })
        var values = [frame.bodyConfidence]
        for joint in BodyJoint.allCases {
            if let item = byJoint[joint] {
                values.append(contentsOf: [
                    item.x,
                    item.y,
                    item.confidence,
                    item.isPresent ? 1 : 0,
                ])
            } else {
                values.append(contentsOf: [0, 0, 0, 0])
            }
        }
        return values
    }

    private func technique(for phase: ServePhaseKind) -> CoachTechniqueLabel? {
        switch phase {
        case .ballToss: .tossPlacement
        case .loading: .loadingSequence
        case .trophyPosition: .trophyAlignment
        case .legDrive: .legDriveTiming
        case .contactPosition: .contactReach
        case .landingFollowThrough: .landingBalance
        default: nil
        }
    }

    private func phase(for technique: CoachTechniqueLabel) -> ServePhaseKind? {
        switch technique {
        case .tossPlacement: deploymentStatus == .pseudoCoachExperiment ? nil : .ballToss
        case .loadingSequence: .loading
        case .trophyAlignment: deploymentStatus == .pseudoCoachExperiment ? nil : .trophyPosition
        case .legDriveTiming: .legDrive
        case .contactReach: .contactPosition
        case .landingBalance: .landingFollowThrough
        }
    }

    private func unavailableNote(for phase: ServePhaseKind) -> String {
        switch phase {
        case .racketDrop: "Insufficient visibility: the model does not track the racket head."
        case .pronation: "Insufficient visibility: 2D body pose cannot resolve forearm rotation."
        case .ballToss: "Insufficient evidence: the research footage does not provide ball tracking or repeated-toss consistency."
        case .trophyPosition: "Insufficient evidence: frontal 2D training footage cannot validate trophy alignment for side/rear captures."
        default: "Insufficient evidence for a responsible experimental score."
        }
    }

    private var phaseScoreNote: String {
        switch deploymentStatus {
        case .pseudoCoachExperiment:
            "Experimental pseudo-coach estimate from visible 2D body joints; not independently coach-validated."
        case .evaluationCandidate:
            "Evaluation-only estimate from the exact staged candidate; accuracy release gates have not passed."
        case .validatedRelease:
            "Validated on-device estimate from the signed ServeAI release."
        }
    }

    private var technicalMetricContext: String {
        switch deploymentStatus {
        case .pseudoCoachExperiment:
            "Research-only pseudo-label model; use as a review aid, not validated coaching advice."
        case .evaluationCandidate:
            "Evaluation-only candidate output; use for repeatability and coach comparison, not coaching advice."
        case .validatedRelease:
            "Validated against held-out, independently adjudicated coach labels."
        }
    }

    private func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
        min(upper, max(lower, value))
    }
}

struct BundledValidatedServeInferenceModel: ServeInferenceModel {
    let identifier = "serveai.validated-release"
    let version = "signed-bundle"
    private let releaseLoader: BundledValidatedModelReleaseLoader

    init(releaseLoader: BundledValidatedModelReleaseLoader = BundledValidatedModelReleaseLoader()) {
        self.releaseLoader = releaseLoader
    }

    func predict(
        features: ServeModelFeatureSequence,
        skillLevel: SkillLevel
    ) async throws -> ServeTechniqueModelPrediction {
        let release = try await Task.detached(priority: .userInitiated) {
            try releaseLoader.load()
        }.value
        return try await BundledExperimentalServeInferenceModel(verifiedRelease: release).predict(
            features: features,
            skillLevel: skillLevel
        )
    }
}
