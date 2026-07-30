import Foundation

protocol RecordingQualityAssessing: Sendable {
    func assess(videoURL: URL, cameraAngle: CameraAngle) async throws -> RecordingQualityReport
}

struct RecordingQualityPolicy: Sendable {
    var preferredMinimumDuration = 3.0
    var preferredMaximumDuration = 15.0
    var blockingShortEdge = 480
    var preferredShortEdge = 720
    var preferredFrameRate = 30.0
    var blockingPoseCoverage = 0.45
    var preferredPoseCoverage = 0.70
    var blockingMeanConfidence = 0.35
    var preferredMeanConfidence = 0.55
    var blockingFullBodyCoverage = 0.30
    var preferredFullBodyCoverage = 0.60
    var blockingEdgeClippingRatio = 0.65
    var preferredMaximumEdgeClippingRatio = 0.35
}

struct RecordingQualityEvaluator: Sendable {
    let policy: RecordingQualityPolicy

    init(policy: RecordingQualityPolicy = RecordingQualityPolicy()) {
        self.policy = policy
    }

    func evaluate(
        metadata: VideoMetadata,
        poseFrames: [PoseFrame],
        additionalIssues: [RecordingQualityIssue] = []
    ) -> RecordingQualityReport {
        let sampledCount = max(metadata.sampledFrames, 1)
        let poseCoverage = Double(poseFrames.count) / Double(sampledCount)
        let meanConfidence = poseFrames.isEmpty
            ? 0
            : poseFrames.map(\.bodyConfidence).reduce(0, +) / Double(poseFrames.count)
        let fullBodyCount = poseFrames.filter(hasFullBody).count
        let fullBodyCoverage = Double(fullBodyCount) / Double(sampledCount)
        let clippedCount = poseFrames.filter(isNearFrameEdge).count
        let edgeClippingRatio = poseFrames.isEmpty
            ? 0
            : Double(clippedCount) / Double(poseFrames.count)

        var issues = additionalIssues
        issues.append(contentsOf: metadataIssues(metadata))
        issues.append(contentsOf: poseIssues(
            poseFrames: poseFrames,
            poseCoverage: poseCoverage,
            meanConfidence: meanConfidence,
            fullBodyCoverage: fullBodyCoverage,
            edgeClippingRatio: edgeClippingRatio
        ))

        return RecordingQualityReport(
            metadata: metadata,
            poseFrameCount: poseFrames.count,
            poseCoverage: poseCoverage,
            meanPoseConfidence: meanConfidence,
            fullBodyCoverage: fullBodyCoverage,
            edgeClippingRatio: edgeClippingRatio,
            issues: deduplicated(issues)
        )
    }

    private func metadataIssues(_ metadata: VideoMetadata) -> [RecordingQualityIssue] {
        var issues: [RecordingQualityIssue] = []
        if metadata.duration < policy.preferredMinimumDuration {
            issues.append(.init(
                kind: .duration,
                severity: .advisory,
                title: "Very short clip",
                detail: "The recording is \(metadata.duration.formatted(.number.precision(.fractionLength(1)))) seconds, which may omit setup or landing.",
                recovery: "Record 3–12 seconds, beginning before the toss and ending after recovery."
            ))
        } else if metadata.duration > policy.preferredMaximumDuration {
            issues.append(.init(
                kind: .duration,
                severity: .advisory,
                title: "Clip is longer than needed",
                detail: "Extra footage slows analysis and can introduce other people into the sample.",
                recovery: "Trim the clip to one complete serve when possible."
            ))
        }

        let shortEdge = min(metadata.width, metadata.height)
        if shortEdge < policy.blockingShortEdge {
            issues.append(.init(
                kind: .resolution,
                severity: .blocking,
                title: "Resolution is too low",
                detail: "The short edge is \(shortEdge) px; joint locations will be unreliable.",
                recovery: "Record at 720p or higher with the player filling most of the frame."
            ))
        } else if shortEdge < policy.preferredShortEdge {
            issues.append(.init(
                kind: .resolution,
                severity: .advisory,
                title: "Low recording resolution",
                detail: "Fine movements may be missed at \(metadata.width)×\(metadata.height).",
                recovery: "Use 720p or 1080p for the next recording."
            ))
        }

        if metadata.nominalFrameRate > 0, metadata.nominalFrameRate < policy.preferredFrameRate {
            issues.append(.init(
                kind: .frameRate,
                severity: .advisory,
                title: "Low frame rate",
                detail: "At \(Int(metadata.nominalFrameRate.rounded())) fps, fast events such as trophy position and contact may fall between frames.",
                recovery: "Use 30 fps minimum; 60 fps is preferred for timing analysis."
            ))
        }
        return issues
    }

    private func poseIssues(
        poseFrames: [PoseFrame],
        poseCoverage: Double,
        meanConfidence: Double,
        fullBodyCoverage: Double,
        edgeClippingRatio: Double
    ) -> [RecordingQualityIssue] {
        var issues: [RecordingQualityIssue] = []
        if poseCoverage < policy.blockingPoseCoverage {
            issues.append(.init(
                kind: .playerDetection,
                severity: .blocking,
                title: "Player is not consistently detectable",
                detail: "A body pose was found in only \(percent(poseCoverage)) of sampled frames.",
                recovery: "Move the camera closer, improve lighting, and keep the full player visible."
            ))
        } else if poseCoverage < policy.preferredPoseCoverage {
            issues.append(.init(
                kind: .playerDetection,
                severity: .advisory,
                title: "Player tracking drops out",
                detail: "A body pose was found in \(percent(poseCoverage)) of sampled frames.",
                recovery: "Increase contrast between the player and background and avoid backlighting."
            ))
        }

        if !poseFrames.isEmpty, meanConfidence < policy.blockingMeanConfidence {
            issues.append(.init(
                kind: .poseConfidence,
                severity: .blocking,
                title: "Pose confidence is too low",
                detail: "Average joint confidence is \(percent(meanConfidence)).",
                recovery: "Use brighter, even lighting and position the camera closer to the player."
            ))
        } else if !poseFrames.isEmpty, meanConfidence < policy.preferredMeanConfidence {
            issues.append(.init(
                kind: .poseConfidence,
                severity: .advisory,
                title: "Pose confidence is limited",
                detail: "Average joint confidence is \(percent(meanConfidence)).",
                recovery: "Avoid loose clothing, shadows, and background clutter."
            ))
        }

        if fullBodyCoverage < policy.blockingFullBodyCoverage {
            issues.append(.init(
                kind: .fullBodyVisibility,
                severity: .blocking,
                title: "Full body is not visible enough",
                detail: "Key upper- and lower-body joints are visible together in only \(percent(fullBodyCoverage)) of sampled frames.",
                recovery: "Step the camera back and keep head, hands, and feet inside the frame for the entire serve."
            ))
        } else if fullBodyCoverage < policy.preferredFullBodyCoverage {
            issues.append(.init(
                kind: .fullBodyVisibility,
                severity: .advisory,
                title: "Some joints leave the frame",
                detail: "Full-body coverage is \(percent(fullBodyCoverage)).",
                recovery: "Leave more space above the tossing hand and around both feet."
            ))
        }

        if edgeClippingRatio > policy.blockingEdgeClippingRatio {
            issues.append(.init(
                kind: .edgeClipping,
                severity: .blocking,
                title: "Player is too close to the frame edge",
                detail: "The detected pose touches an edge in \(percent(edgeClippingRatio)) of tracked frames.",
                recovery: "Recenter the camera and leave a clear margin around the full service motion."
            ))
        } else if edgeClippingRatio > policy.preferredMaximumEdgeClippingRatio {
            issues.append(.init(
                kind: .edgeClipping,
                severity: .advisory,
                title: "Framing is tight",
                detail: "The detected pose approaches an edge in \(percent(edgeClippingRatio)) of tracked frames.",
                recovery: "Move the camera slightly farther back before the next serve."
            ))
        }
        return issues
    }

    private func hasFullBody(_ frame: PoseFrame) -> Bool {
        let required: [BodyJoint] = [
            .leftShoulder, .rightShoulder,
            .leftWrist, .rightWrist,
            .leftHip, .rightHip,
            .leftKnee, .rightKnee,
            .leftAnkle, .rightAnkle
        ]
        return required.allSatisfy { (frame.joints[$0]?.confidence ?? 0) >= 0.25 }
    }

    private func isNearFrameEdge(_ frame: PoseFrame) -> Bool {
        let points = frame.joints.values.filter { $0.confidence >= 0.25 }
        guard points.count >= 6 else { return false }
        return points.contains { point in
            point.x < 0.025 || point.x > 0.975 || point.y < 0.025 || point.y > 0.975
        }
    }

    private func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }

    private func deduplicated(_ issues: [RecordingQualityIssue]) -> [RecordingQualityIssue] {
        var seen = Set<RecordingQualityIssueKind>()
        return issues.filter { seen.insert($0.kind).inserted }
    }
}

struct VisionRecordingQualityAssessor: RecordingQualityAssessing {
    let frameExtractor: any VideoFrameExtracting
    let poseDetector: any PoseDetectionService
    let evaluator: RecordingQualityEvaluator
    let ambiguityPolicy: PoseAmbiguityPolicy

    init(
        frameExtractor: any VideoFrameExtracting = AVVideoFrameExtractor(),
        poseDetector: any PoseDetectionService = VisionBodyPoseDetectionService(),
        evaluator: RecordingQualityEvaluator = RecordingQualityEvaluator(),
        ambiguityPolicy: PoseAmbiguityPolicy = PoseAmbiguityPolicy()
    ) {
        self.frameExtractor = frameExtractor
        self.poseDetector = poseDetector
        self.evaluator = evaluator
        self.ambiguityPolicy = ambiguityPolicy
    }

    func assess(videoURL: URL, cameraAngle _: CameraAngle) async throws -> RecordingQualityReport {
        let extracted = try await frameExtractor.extractFrames(
            from: videoURL,
            samplesPerSecond: 3,
            maximumFrames: 24
        )
        var poseFrames: [PoseFrame] = []
        var ambiguousFrameCount = 0

        for frame in extracted.frames {
            try Task.checkCancellation()
            do {
                if let pose = try await poseDetector.detectPose(in: frame.image, at: frame.timestamp) {
                    poseFrames.append(pose)
                }
            } catch ServeAIError.multiplePeopleDetected {
                ambiguousFrameCount += 1
            }
        }

        let sustainedAmbiguity = ambiguityPolicy.isBlocking(
            ambiguousFrames: ambiguousFrameCount,
            sampledFrames: extracted.frames.count
        )
        let additionalIssues: [RecordingQualityIssue] = sustainedAmbiguity ? [
            .init(
                kind: .multiplePeople,
                severity: .blocking,
                title: "Multiple foreground players are visible",
                detail: "Two similarly sized body poses compete for the server track in \(ambiguousFrameCount) of \(extracted.frames.count) sampled frames.",
                recovery: "Crop the clip or re-record so one foreground player remains clearly dominant."
            )
        ] : []

        return evaluator.evaluate(
            metadata: extracted.metadata,
            poseFrames: poseFrames,
            additionalIssues: additionalIssues
        )
    }
}

#if DEBUG
struct PreviewRecordingQualityAssessor: RecordingQualityAssessing {
    func assess(videoURL _: URL, cameraAngle _: CameraAngle) async throws -> RecordingQualityReport {
        try await Task.sleep(for: .milliseconds(450))
        let metadata = VideoMetadata(
            duration: 6.8,
            width: 1920,
            height: 1080,
            nominalFrameRate: 60,
            usableFrames: 15,
            sampledFrames: 20
        )
        return RecordingQualityReport(
            metadata: metadata,
            poseFrameCount: 15,
            poseCoverage: 0.75,
            meanPoseConfidence: 0.62,
            fullBodyCoverage: 0.25,
            edgeClippingRatio: 0.70,
            issues: [
                .init(
                    kind: .fullBodyVisibility,
                    severity: .blocking,
                    title: "Full body is not visible enough",
                    detail: "The tossing hand and feet leave the frame during the motion.",
                    recovery: "Step the camera back and keep head, hands, and feet visible."
                ),
                .init(
                    kind: .edgeClipping,
                    severity: .blocking,
                    title: "Player is too close to the frame edge",
                    detail: "The detected pose touches an edge in 70% of tracked frames.",
                    recovery: "Recenter the camera and leave a clear margin around the serve."
                )
            ]
        )
    }
}

/// A deterministic, Debug-only quality gate used to exercise the complete
/// review-to-report flow in Simulator. It does not claim to have inspected the
/// supplied video; the downstream analyzer must also run in explicitly labeled
/// simulated mode.
struct AcceptancePreviewRecordingQualityAssessor: RecordingQualityAssessing {
    func assess(videoURL _: URL, cameraAngle _: CameraAngle) async throws -> RecordingQualityReport {
        try await Task.sleep(for: .milliseconds(150))
        let metadata = VideoMetadata(
            duration: 6.8,
            width: 1080,
            height: 1920,
            nominalFrameRate: 60,
            usableFrames: 20,
            sampledFrames: 20
        )
        return RecordingQualityReport(
            metadata: metadata,
            poseFrameCount: 20,
            poseCoverage: 1,
            meanPoseConfidence: 0.92,
            fullBodyCoverage: 1,
            edgeClippingRatio: 0,
            issues: []
        )
    }
}
#endif
