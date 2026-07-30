import Foundation

struct VisionPoseAnalysisService: ServeAnalysisService {
    let source: AnalysisSource = .vision
    private let frameExtractor: any VideoFrameExtracting
    private let poseDetector: any PoseDetectionService
    private let poseTracker: any PoseTrackingService
    private let phaseDetector: any ServePhaseDetecting
    private let metricsCalculator: any ServeMetricsCalculating
    private let confidenceCalculator: any AnalysisConfidenceCalculating
    private let feedbackGenerator: any ServeFeedbackGenerating
    private let videoHasher: any VideoContentHashing
    private let ambiguityPolicy: PoseAmbiguityPolicy

    init(
        frameExtractor: any VideoFrameExtracting,
        poseDetector: any PoseDetectionService,
        poseTracker: any PoseTrackingService,
        phaseDetector: any ServePhaseDetecting,
        metricsCalculator: any ServeMetricsCalculating,
        confidenceCalculator: any AnalysisConfidenceCalculating,
        feedbackGenerator: any ServeFeedbackGenerating,
        videoHasher: any VideoContentHashing = SHA256VideoContentHasher(),
        ambiguityPolicy: PoseAmbiguityPolicy = PoseAmbiguityPolicy()
    ) {
        self.frameExtractor = frameExtractor
        self.poseDetector = poseDetector
        self.poseTracker = poseTracker
        self.phaseDetector = phaseDetector
        self.metricsCalculator = metricsCalculator
        self.confidenceCalculator = confidenceCalculator
        self.feedbackGenerator = feedbackGenerator
        self.videoHasher = videoHasher
        self.ambiguityPolicy = ambiguityPolicy
    }

    func analyze(
        videoURL: URL,
        cameraAngle: CameraAngle,
        skillLevel: SkillLevel,
        progress: @escaping @MainActor @Sendable (AnalysisProgress) -> Void
    ) async throws -> ServeAnalysis {
        await progress(AnalysisProgress(stage: .preparing, fraction: 0.05, detail: "Sampling frames on this device"))
        let extracted = try await frameExtractor.extractFrames(from: videoURL, samplesPerSecond: 15, maximumFrames: 180)

        await progress(AnalysisProgress(stage: .detecting, fraction: 0.18, detail: "Locking onto the primary athlete"))
        var detected: [PoseFrame] = []
        var ambiguousFrameCount = 0
        for (index, frame) in extracted.frames.enumerated() {
            try Task.checkCancellation()
            do {
                if let pose = try await poseDetector.detectPose(
                    in: frame.image,
                    at: frame.timestamp
                ) {
                    detected.append(pose)
                }
            } catch ServeAIError.multiplePeopleDetected {
                ambiguousFrameCount += 1
            }
            if index.isMultiple(of: 12) {
                let fraction = 0.18 + 0.28 * Double(index + 1) / Double(extracted.frames.count)
                await progress(AnalysisProgress(stage: .detecting, fraction: fraction, detail: "\(detected.count) usable poses found"))
            }
        }
        if ambiguityPolicy.isBlocking(
            ambiguousFrames: ambiguousFrameCount,
            sampledFrames: extracted.frames.count
        ) {
            throw ServeAIError.multiplePeopleDetected
        }
        guard !detected.isEmpty else { throw ServeAIError.noPersonDetected }
        guard detected.count >= max(10, extracted.frames.count / 5) else { throw ServeAIError.poseTrackingFailed }

        await progress(AnalysisProgress(stage: .tracking, fraction: 0.52, detail: "Smoothing joint trajectories"))
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
                requestedSamplesPerSecond: 15,
                smoothingWindow: 5,
                sampledFrameCount: extracted.frames.count,
                detectedFrameCount: tracked.count
            )
        )
        let phases = phaseDetector.detect(in: tracked)
        guard phases.count >= 6 else { throw ServeAIError.poseTrackingFailed }

        await progress(AnalysisProgress(stage: .phases, fraction: 0.68, detail: "Anchoring visible serve events"))
        let metrics = metricsCalculator.calculate(frames: tracked, phases: phases)
        let phaseScores = HeuristicPhaseScorer().score(frames: tracked, phases: phases)

        await progress(AnalysisProgress(stage: .technique, fraction: 0.82, detail: "Calculating evidence-based estimates"))
        let missing = missingAreas(in: tracked)
        let poseQuality = tracked.reduce(0) { $0 + $1.bodyConfidence } / Double(tracked.count)
        let confidence = confidenceCalculator.calculate(
            visibility: Double(tracked.count) / Double(extracted.frames.count),
            poseQuality: poseQuality,
            usableFrames: tracked.count,
            expectedFrames: extracted.frames.count,
            cameraSuitability: 0.82,
            missingAreas: missing
        )
        let insights = feedbackGenerator.generate(from: phaseScores, metrics: metrics, skillLevel: skillLevel)
        let drills = feedbackGenerator.selectDrills(for: insights, skillLevel: skillLevel)
        let score = ScoreCalculator().weightedScore(for: phaseScores) ?? 0

        await progress(AnalysisProgress(stage: .feedback, fraction: 0.95, detail: "Prioritizing clear corrections and drills"))
        var limitations = [
            AnalysisLimitation(title: "Racket not tracked", detail: "The Vision body-pose request tracks joints, not the racket head. ServeAI does not estimate racket-head speed."),
            AnalysisLimitation(title: "Single-view estimate", detail: "Depth and rotation outside the image plane cannot be measured precisely from one camera."),
            AnalysisLimitation(title: "Evidence quality is not accuracy", detail: "High video evidence means the body joints were tracked clearly. These heuristic technique scores have not been validated against independent coach ground truth.")
        ]
        if !missing.isEmpty {
            limitations.append(AnalysisLimitation(title: "Intermittent visibility", detail: "Often missing or obscured: \(missing.joined(separator: ", "))."))
        }
        let metadata = VideoMetadata(duration: extracted.metadata.duration, width: extracted.metadata.width, height: extracted.metadata.height, nominalFrameRate: extracted.metadata.nominalFrameRate, usableFrames: tracked.count, sampledFrames: extracted.metadata.sampledFrames)
        await progress(AnalysisProgress(stage: .feedback, fraction: 1, detail: "On-device report ready"))
        return ServeAnalysis(overallScore: score, skillLevel: skillLevel, cameraAngle: cameraAngle, source: .vision, videoURL: videoURL, phaseScores: phaseScores, technicalMetrics: metrics, insights: insights, drills: drills, limitations: limitations, confidence: confidence, videoMetadata: metadata, modelFeatureEvidence: featureEvidence)
    }

    private func missingAreas(in frames: [PoseFrame]) -> [String] {
        let required: [(String, [BodyJoint])] = [
            ("feet", [.leftAnkle, .rightAnkle]),
            ("hitting arm", [.leftShoulder, .rightShoulder, .leftElbow, .rightElbow, .leftWrist, .rightWrist]),
            ("knees", [.leftKnee, .rightKnee])
        ]
        return required.compactMap { label, joints in
            let visible = frames.filter { frame in joints.contains { frame.joints[$0] != nil } }.count
            return Double(visible) / Double(frames.count) < 0.55 ? label : nil
        }
    }
}
