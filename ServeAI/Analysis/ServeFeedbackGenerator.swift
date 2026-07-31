import Foundation

protocol ServeFeedbackGenerating: Sendable {
    func generate(
        from phases: [PhaseScore],
        metrics: [TechnicalMetric],
        skillLevel: SkillLevel,
        preferredPriority: CoachTechniqueLabel?
    ) -> [CoachingInsight]
    func selectDrills(for insights: [CoachingInsight], skillLevel: SkillLevel) -> [RecommendedDrill]
}

extension ServeFeedbackGenerating {
    func generate(
        from phases: [PhaseScore],
        metrics: [TechnicalMetric],
        skillLevel: SkillLevel
    ) -> [CoachingInsight] {
        generate(from: phases, metrics: metrics, skillLevel: skillLevel, preferredPriority: nil)
    }
}

struct ServeFeedbackGenerator: ServeFeedbackGenerating {
    func generate(
        from phases: [PhaseScore],
        metrics _: [TechnicalMetric],
        skillLevel _: SkillLevel,
        preferredPriority: CoachTechniqueLabel?
    ) -> [CoachingInsight] {
        let measurable = phases.filter { $0.score != nil }
        let coachingEligible = measurable.filter { $0.confidence != .low }
        let strongest = coachingEligible.max { ($0.score ?? 0) < ($1.score ?? 0) }
        let weakest = coachingEligible.min { ($0.score ?? 100) < ($1.score ?? 100) }
        var insights: [CoachingInsight] = []

        if let strongest {
            insights.append(CoachingInsight(
                title: "\(strongest.phase.shortTitle) is a stable base",
                category: strongest.phase.title,
                severity: .strength,
                observation: strongest.note,
                whyItMatters: "A repeatable phase gives the rest of the motion a reliable reference point.",
                correction: "Keep this cue unchanged while working on the priority below.",
                confidence: strongest.confidence,
                relatedPhase: strongest.phase
            ))
        }

        let modelRanked = preferredPriority
            .flatMap(priorityPhase)
            .flatMap { phase in coachingEligible.first(where: { $0.phase == phase }) }
        if let priority = modelRanked ?? weakest {
            insights.append(priorityInsight(for: priority))
        }

        if phases.first(where: { $0.phase == .racketDrop })?.score == nil {
            insights.append(CoachingInsight(
                title: "Racket path needs a clearer view",
                category: "Racket preparation",
                severity: .opportunity,
                observation: "Body pose tracking followed the wrist and elbow, but it could not reliably locate the racket head.",
                whyItMatters: "Wrist position alone cannot establish racket drop depth or racket-head speed.",
                correction: "Use brighter lighting and keep the full racket separated from the torso in frame.",
                recommendedDrillID: "racket-drop-sock",
                confidence: .low,
                relatedPhase: .racketDrop
            ))
        }

        return Array(insights.prefix(4))
    }

    func selectDrills(for insights: [CoachingInsight], skillLevel: SkillLevel) -> [RecommendedDrill] {
        let requested = insights.compactMap(\.recommendedDrillID)
        var selected: [RecommendedDrill] = []
        for id in requested where selected.count < 3 {
            if let drill = DrillLibrary.drill(id: id), !selected.contains(where: { $0.id == drill.id }) { selected.append(drill) }
        }
        if selected.isEmpty {
            selected = DrillLibrary.all.filter { difficultyRank($0.difficulty) <= difficultyRank(skillLevel) }.prefix(3).map { $0 }
        }
        return Array(selected.prefix(3))
    }

    private func difficultyRank(_ level: SkillLevel) -> Int {
        switch level {
        case .beginner: 0
        case .intermediate: 1
        case .advanced: 2
        case .competitive: 3
        }
    }

    private func priorityInsight(for score: PhaseScore) -> CoachingInsight {
        switch score.phase {
        case .ballToss:
            CoachingInsight(title: "Finish the toss-arm path", category: "Ball toss", severity: .priority, observation: score.note, whyItMatters: "A smooth, extended toss-arm path provides a repeatable timing reference for the loading sequence.", correction: "Rehearse the toss without swinging: extend the elbow comfortably and let the wrist continue upward. Judge actual ball placement separately, because this analysis does not track the ball.", recommendedDrillID: "toss-target", confidence: score.confidence, relatedPhase: .ballToss)
        case .loading, .trophyPosition, .legDrive:
            CoachingInsight(title: "Sequence the load before driving up", category: "Loading and leg drive", severity: .priority, observation: score.note, whyItMatters: "A complete load creates time for the trunk and hitting arm to accelerate in order.", correction: "Pause briefly at trophy position in practice, confirm balance, then drive vertically before rotating through.", recommendedDrillID: "trophy-freeze", confidence: score.confidence, relatedPhase: score.phase)
        case .contactPosition, .upwardAcceleration:
            CoachingInsight(title: "Reach taller through contact", category: "Contact", severity: .priority, observation: score.note, whyItMatters: "More complete extension raises the contact window and supports a steeper, safer serve trajectory.", correction: "Keep the head up and extend the hitting arm before allowing the follow-through to pull it down.", recommendedDrillID: "contact-height", confidence: score.confidence, relatedPhase: score.phase)
        case .racketDrop:
            CoachingInsight(title: "Let the hitting arm stay loose", category: "Racket preparation", severity: .priority, observation: score.note, whyItMatters: "A continuous arm loop helps preserve acceleration into contact.", correction: "Rehearse a slow, relaxed serve loop and avoid forcing the racket behind the back.", recommendedDrillID: "racket-drop-sock", confidence: score.confidence, relatedPhase: score.phase)
        case .pronation:
            CoachingInsight(title: "Allow rotation after extension", category: "Arm action", severity: .priority, observation: score.note, whyItMatters: "A relaxed post-contact turn can support a continuous follow-through without forcing a wrist snap.", correction: "Shadow the swing slowly with the racket edge leading upward, then let the strings turn outward after the imagined contact.", recommendedDrillID: "pronation-shadow", confidence: score.confidence, relatedPhase: score.phase)
        case .landingFollowThrough:
            CoachingInsight(title: "Finish under control", category: "Follow-through", severity: .priority, observation: score.note, whyItMatters: "A balanced landing is evidence that force traveled toward the target instead of leaking sideways.", correction: "Serve below full pace and hold the finish for three seconds with the chest facing into the court.", recommendedDrillID: "hold-balance", confidence: score.confidence, relatedPhase: score.phase)
        default:
            CoachingInsight(title: "Build a calmer starting shape", category: score.phase.title, severity: .priority, observation: score.note, whyItMatters: "A balanced setup reduces compensations later in the motion.", correction: "Rehearse the full motion slowly and preserve the same starting alignment on every repetition.", recommendedDrillID: "shadow-serve", confidence: score.confidence, relatedPhase: score.phase)
        }
    }

    private func priorityPhase(for label: CoachTechniqueLabel) -> ServePhaseKind? {
        switch label {
        case .loadingSequence: .loading
        case .legDriveTiming: .legDrive
        case .contactReach: .contactPosition
        case .landingBalance: .landingFollowThrough
        case .tossPlacement: .ballToss
        case .trophyAlignment: .trophyPosition
        }
    }
}
