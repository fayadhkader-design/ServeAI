import Foundation

struct ServeTechniqueModelPrediction: Sendable {
    let modelIdentifier: String
    let modelVersion: String
    let modelArtifactSHA256: String?
    let validatedReleaseVerified: Bool
    let detectedPhases: [DetectedServePhase]
    let phaseScores: [PhaseScore]
    let technicalMetrics: [TechnicalMetric]
    let coachingPriority: CoachTechniqueLabel?
}

protocol ServeInferenceModel: Sendable {
    var identifier: String { get }
    var version: String { get }

    func predict(
        features: ServeModelFeatureSequence,
        skillLevel: SkillLevel
    ) async throws -> ServeTechniqueModelPrediction
}

struct UnavailableServeInferenceModel: ServeInferenceModel {
    let identifier = "serveai.technique"
    let version = "not-installed"

    func predict(
        features _: ServeModelFeatureSequence,
        skillLevel _: SkillLevel
    ) async throws -> ServeTechniqueModelPrediction {
        throw ServeAIError.modelUnavailable("no validated .mlmodelc has been installed")
    }
}

struct CoreMLServeAnalysisService: ServeAnalysisService {
    let source: AnalysisSource
    private let frameExtractor: any VideoFrameExtracting
    private let poseDetector: any PoseDetectionService
    private let poseTracker: any PoseTrackingService
    private let model: any ServeInferenceModel
    private let confidenceCalculator: any AnalysisConfidenceCalculating
    private let feedbackGenerator: any ServeFeedbackGenerating
    private let videoHasher: any VideoContentHashing

    init(
        source: AnalysisSource = .coreML,
        frameExtractor: any VideoFrameExtracting,
        poseDetector: any PoseDetectionService,
        poseTracker: any PoseTrackingService,
        model: any ServeInferenceModel,
        confidenceCalculator: any AnalysisConfidenceCalculating,
        feedbackGenerator: any ServeFeedbackGenerating,
        videoHasher: any VideoContentHashing = SHA256VideoContentHasher()
    ) {
        self.source = source
        self.frameExtractor = frameExtractor
        self.poseDetector = poseDetector
        self.poseTracker = poseTracker
        self.model = model
        self.confidenceCalculator = confidenceCalculator
        self.feedbackGenerator = feedbackGenerator
        self.videoHasher = videoHasher
    }

    func analyze(
        videoURL: URL,
        cameraAngle: CameraAngle,
        skillLevel: SkillLevel,
        progress: @escaping @MainActor @Sendable (AnalysisProgress) -> Void
    ) async throws -> ServeAnalysis {
        await progress(.init(stage: .preparing, fraction: 0.05, detail: "Preparing model input"))
        let extracted = try await frameExtractor.extractFrames(from: videoURL, samplesPerSecond: 30, maximumFrames: 360)

        await progress(.init(stage: .detecting, fraction: 0.20, detail: "Extracting body landmarks"))
        var detected: [PoseFrame] = []
        for (index, frame) in extracted.frames.enumerated() {
            try Task.checkCancellation()
            if let pose = try await poseDetector.detectPose(in: frame.image, at: frame.timestamp) {
                detected.append(pose)
            }
            if index.isMultiple(of: 18) {
                await progress(.init(
                    stage: .detecting,
                    fraction: 0.20 + (0.30 * Double(index + 1) / Double(extracted.frames.count)),
                    detail: "\(detected.count) model-ready frames"
                ))
            }
        }
        guard detected.count >= max(18, extracted.frames.count / 2) else { throw ServeAIError.poseTrackingFailed }

        await progress(.init(stage: .tracking, fraction: 0.55, detail: "Normalizing joint trajectories"))
        let tracked = poseTracker.smooth(detected, window: 5)
        let features = ServeModelFeatureEncoder().encode(
            frames: tracked,
            duration: extracted.metadata.duration,
            cameraAngle: cameraAngle
        )
        let featureEvidence = ServeModelFeatureEvidence(
            sequence: features,
            provenance: ServeModelFeatureProvenance(
                poseDetectorIdentifier: poseDetector.provenanceIdentifier,
                poseDetectorVersion: poseDetector.provenanceVersion,
                videoSHA256: try await videoHasher.sha256(of: videoURL),
                requestedSamplesPerSecond: 30,
                smoothingWindow: 5,
                sampledFrameCount: extracted.frames.count,
                detectedFrameCount: tracked.count
            )
        )

        await progress(.init(
            stage: .technique,
            fraction: 0.75,
            detail: techniqueProgressDetail
        ))
        let prediction = try await model.predict(features: features, skillLevel: skillLevel)
        guard prediction.detectedPhases.count >= 6, !prediction.phaseScores.isEmpty else {
            throw ServeAIError.poseTrackingFailed
        }

        let visibility = Double(tracked.count) / Double(max(extracted.frames.count, 1))
        let poseQuality = tracked.map(\.bodyConfidence).reduce(0, +) / Double(tracked.count)
        let confidence = confidenceCalculator.calculate(
            visibility: visibility,
            poseQuality: poseQuality,
            usableFrames: tracked.count,
            expectedFrames: extracted.frames.count,
            cameraSuitability: 0.82,
            missingAreas: []
        )
        let insights = feedbackGenerator.generate(
            from: prediction.phaseScores,
            metrics: prediction.technicalMetrics,
            skillLevel: skillLevel,
            preferredPriority: prediction.coachingPriority
        )
        let drills = feedbackGenerator.selectDrills(for: insights, skillLevel: skillLevel)
        let score = ScoreCalculator().weightedScore(for: prediction.phaseScores) ?? 0

        await progress(.init(
            stage: .feedback,
            fraction: 1,
            detail: feedbackProgressDetail
        ))
        let sourceLimitations: [AnalysisLimitation]
        switch source {
        case .experimentalCoreML:
            sourceLimitations = [
                .init(
                    title: "Experimental model",
                    detail: "This model learned research-based pseudo-labels, not independent coach ground truth. It failed ServeAI's technique and priority release gates."
                ),
                .init(
                    title: "Training-view mismatch",
                    detail: "Multi-player pretraining used frontal, staged indoor serves without a ball; side and rear iPhone accuracy has not been established."
                ),
                .init(
                    title: "Research-only source terms",
                    detail: "The THETIS training source is not cleared for a commercial production model."
                ),
            ]
        case .evaluationCoreML:
            sourceLimitations = [
                .init(
                    title: "Evaluation candidate · not released",
                    detail: "This exact staged model is running only to measure repeatability and compare its outputs with independent coach labels."
                ),
                .init(
                    title: "Accuracy gates pending",
                    detail: "Technique ratings and coaching priority must still pass held-out player, subgroup, and repeatability requirements before release."
                ),
                .init(
                    title: "Do not coach from this report",
                    detail: "Treat scores and priorities as evaluation data until a signed production release verifies every accuracy and rights gate."
                ),
            ]
        case .coreML, .vision, .researchCapture, .simulated:
            sourceLimitations = []
        }
        return ServeAnalysis(
            overallScore: score,
            skillLevel: skillLevel,
            cameraAngle: cameraAngle,
            source: source,
            videoURL: videoURL,
            phaseScores: prediction.phaseScores,
            technicalMetrics: prediction.technicalMetrics,
            insights: insights,
            drills: drills,
            limitations: sourceLimitations + [
                .init(title: "Model traceability", detail: "Generated by \(prediction.modelIdentifier) version \(prediction.modelVersion)."),
                .init(title: "Single-view estimate", detail: "Depth outside the image plane remains limited from one camera."),
                .init(title: "Evidence quality is not correctness", detail: "Video evidence measures visibility and pose tracking. It is not the probability that this score or coaching priority is correct.")
            ],
            confidence: confidence,
            videoMetadata: .init(
                duration: extracted.metadata.duration,
                width: extracted.metadata.width,
                height: extracted.metadata.height,
                nominalFrameRate: extracted.metadata.nominalFrameRate,
                usableFrames: tracked.count,
                sampledFrames: extracted.metadata.sampledFrames
            ),
            modelFeatureEvidence: featureEvidence,
            modelTrace: AnalysisModelTrace(
                modelIdentifier: prediction.modelIdentifier,
                modelVersion: prediction.modelVersion,
                modelArtifactSHA256: prediction.modelArtifactSHA256,
                validatedReleaseVerified: prediction.validatedReleaseVerified,
                appBuildIdentifier: Self.appBuildIdentifier
            )
        )
    }

    private static var appBuildIdentifier: String {
        let bundle = Bundle.main
        let identifier = bundle.bundleIdentifier ?? "com.serveai.app"
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return "\(identifier)/\(version)(\(build))"
    }

    private var techniqueProgressDetail: String {
        switch source {
        case .experimentalCoreML: "Running experimental research model"
        case .evaluationCoreML: "Running exact evaluation candidate"
        case .coreML: "Running validated technique model"
        case .vision, .researchCapture, .simulated: "Evaluating technique"
        }
    }

    private var feedbackProgressDetail: String {
        switch source {
        case .experimentalCoreML: "Experimental report ready"
        case .evaluationCoreML: "Evaluation-only report ready"
        case .coreML: "Validated model report ready"
        case .vision, .researchCapture, .simulated: "Report ready"
        }
    }
}
