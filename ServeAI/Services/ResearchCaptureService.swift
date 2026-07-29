import Foundation

struct ResearchCaptureService: Sendable {
    private let frameExtractor: any VideoFrameExtracting
    private let poseDetector: any PoseDetectionService
    private let poseTracker: any PoseTrackingService
    private let videoHasher: any VideoContentHashing

    init(
        frameExtractor: any VideoFrameExtracting = AVVideoFrameExtractor(),
        poseDetector: any PoseDetectionService = VisionBodyPoseDetectionService(),
        poseTracker: any PoseTrackingService = MovingAveragePoseTrackingService(),
        videoHasher: any VideoContentHashing = SHA256VideoContentHasher()
    ) {
        self.frameExtractor = frameExtractor
        self.poseDetector = poseDetector
        self.poseTracker = poseTracker
        self.videoHasher = videoHasher
    }

    func makeRejectedSample(
        videoURL: URL,
        slot: CapturePlanSlot,
        qualityReport: RecordingQualityReport
    ) async throws -> ServeAnalysis {
        guard slot.isFailureExample,
              qualityReport.status == .rejected else {
            throw ServeAIError.poseTrackingFailed
        }

        let extracted = try await frameExtractor.extractFrames(
            from: videoURL,
            samplesPerSecond: 15,
            maximumFrames: 180
        )
        var detected: [PoseFrame] = []
        var multiplePersonFrames = 0
        for frame in extracted.frames {
            try Task.checkCancellation()
            do {
                if let pose = try await poseDetector.detectPose(in: frame.image, at: frame.timestamp) {
                    detected.append(pose)
                }
            } catch ServeAIError.multiplePeopleDetected {
                multiplePersonFrames += 1
            }
        }

        // Negative samples still need enough authentic single-player observations for
        // the fixed temporal feature contract. Ambiguous frames are omitted, never
        // reassigned to an arbitrary person or replaced with fabricated joint data.
        guard detected.count >= 18 else { throw ServeAIError.poseTrackingFailed }
        let tracked = poseTracker.smooth(detected, window: 5)
        let sequence = ServeModelFeatureEncoder().encode(
            frames: tracked,
            duration: extracted.metadata.duration,
            cameraAngle: slot.cameraAngle
        )
        let evidence = ServeModelFeatureEvidence(
            sequence: sequence,
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
        guard evidence.isCompleteForDataset else { throw ServeAIError.poseTrackingFailed }

        let meanConfidence = tracked.map(\.bodyConfidence).reduce(0, +) / Double(tracked.count)
        let visibility = Double(tracked.count) / Double(max(extracted.frames.count, 1))
        var missingAreas = qualityReport.issues.map(\.title)
        if multiplePersonFrames > 0 {
            missingAreas.append("Ambiguous multi-person frames excluded: \(multiplePersonFrames)")
        }
        let confidence = AnalysisConfidence(
            level: .low,
            visibilityScore: min(visibility, 0.49),
            poseDetectionQuality: min(meanConfidence, 0.49),
            cameraSuitability: 0,
            usableFrameCount: tracked.count,
            missingAreas: missingAreas
        )
        let limitations = [
            AnalysisLimitation(
                title: "Research sample only",
                detail: "This recording intentionally failed the user-facing quality gate. ServeAI generated no technique score, priority, strength, correction, or drill."
            )
        ] + qualityReport.issues.map { issue in
            AnalysisLimitation(title: issue.title, detail: issue.detail)
        }
        let metadata = VideoMetadata(
            duration: extracted.metadata.duration,
            width: extracted.metadata.width,
            height: extracted.metadata.height,
            nominalFrameRate: extracted.metadata.nominalFrameRate,
            usableFrames: tracked.count,
            sampledFrames: extracted.frames.count
        )
        return ServeAnalysis(
            overallScore: 0,
            skillLevel: slot.skillLevel,
            cameraAngle: slot.cameraAngle,
            source: .researchCapture,
            videoURL: videoURL,
            phaseScores: [],
            technicalMetrics: [],
            insights: [],
            drills: [],
            limitations: limitations,
            confidence: confidence,
            videoMetadata: metadata,
            modelFeatureEvidence: evidence
        )
    }
}
