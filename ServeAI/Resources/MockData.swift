import Foundation

enum MockData {
    static func analysis(
        cameraAngle: CameraAngle = .side,
        skillLevel: SkillLevel = .intermediate,
        videoURL: URL? = nil,
        date: Date = .now,
        scoreOffset: Int = 0
    ) -> ServeAnalysis {
        func adjusted(_ value: Int) -> Int { max(0, min(100, value + scoreOffset)) }
        let scores: [PhaseScore] = [
            PhaseScore(phase: .startingStance, score: adjusted(82), confidence: .high, note: "Balanced platform stance with a stable base."),
            PhaseScore(phase: .ballToss, score: adjusted(61), confidence: .medium, note: "The tossing wrist peaks slightly behind the front shoulder line."),
            PhaseScore(phase: .loading, score: adjusted(73), confidence: .high, note: "Knee bend is visible and remains centered."),
            PhaseScore(phase: .trophyPosition, score: adjusted(78), confidence: .high, note: "Shoulder tilt and hitting-elbow spacing are well organized."),
            PhaseScore(phase: .legDrive, score: adjusted(68), confidence: .medium, note: "Knee extension begins, but the center moves sideways before rising."),
            PhaseScore(phase: .racketDrop, score: nil, confidence: .low, note: "Insufficient visibility — the racket head blends into the background."),
            PhaseScore(phase: .upwardAcceleration, score: adjusted(72), confidence: .medium, note: "The hitting wrist accelerates upward after the legs extend."),
            PhaseScore(phase: .contactPosition, score: adjusted(76), confidence: .medium, note: "Arm extension is good; the head begins dropping just before contact."),
            PhaseScore(phase: .pronation, score: nil, confidence: .low, note: "Insufficient visibility — forearm rotation is partially obscured."),
            PhaseScore(phase: .landingFollowThrough, score: adjusted(84), confidence: .high, note: "The landing is controlled with momentum moving into the court.")
        ]
        let generator = ServeFeedbackGenerator()
        let metrics = [
            TechnicalMetric(title: "Deepest knee flexion", value: "108°", context: "Estimated from the front leg during loading.", confidence: .high, relatedPhase: .loading),
            TechnicalMetric(title: "Shoulder tilt", value: "24°", context: "Estimated at trophy position.", confidence: .medium, relatedPhase: .trophyPosition),
            TechnicalMetric(title: "Contact arm extension", value: "91%", context: "Hitting-arm length relative to its visible maximum.", confidence: .medium, relatedPhase: .contactPosition),
            TechnicalMetric(title: "Landing movement", value: "+0.32 body lengths", context: "Estimated movement toward the court from setup to landing.", confidence: .high, relatedPhase: .landingFollowThrough)
        ]
        let insights = generator.generate(from: scores, metrics: metrics, skillLevel: skillLevel)
        let overall = ScoreCalculator().weightedScore(for: scores) ?? 0
        return ServeAnalysis(
            createdAt: date,
            overallScore: overall,
            skillLevel: skillLevel,
            cameraAngle: cameraAngle,
            source: .simulated,
            videoURL: videoURL,
            phaseScores: scores,
            technicalMetrics: metrics,
            insights: insights,
            drills: generator.selectDrills(for: insights, skillLevel: skillLevel),
            limitations: [
                AnalysisLimitation(title: "Simulated analysis", detail: "This report uses realistic sample values to exercise the complete interface. It is not an assessment of your uploaded video.", symbol: "testtube.2"),
                AnalysisLimitation(title: "Racket not tracked", detail: "Apple body pose tracks joints, not the racket head. No racket-head speed is estimated."),
                AnalysisLimitation(title: "Single camera view", detail: "Depth and out-of-plane rotation cannot be measured precisely from one phone angle.")
            ],
            confidence: AnalysisConfidence(level: .medium, visibilityScore: 0.84, poseDetectionQuality: 0.76, cameraSuitability: 0.81, usableFrameCount: 126, missingAreas: ["Racket head", "Forearm rotation after contact"]),
            videoMetadata: VideoMetadata(duration: 6.4, width: 1920, height: 1080, nominalFrameRate: 60, usableFrames: 126, sampledFrames: 144)
        )
    }

    static var history: [ServeAnalysis] {
        [
            analysis(date: .now.addingTimeInterval(-86400 * 12), scoreOffset: -7),
            analysis(cameraAngle: .rear, date: .now.addingTimeInterval(-86400 * 5), scoreOffset: -3),
            analysis(date: .now, scoreOffset: 0)
        ]
    }
}
