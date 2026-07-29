import Foundation

struct BinaryQualityEvaluation: Sendable {
    let groundTruthUsable: Bool
    let predictedUsable: Bool
}

struct PhaseBoundaryEvaluation: Sendable {
    let phase: ServePhaseKind
    let groundTruthStart: TimeInterval
    let predictedStart: TimeInterval
    let groundTruthEnd: TimeInterval
    let predictedEnd: TimeInterval
}

struct PhaseVisibilityEvaluation: Sendable {
    let phase: ServePhaseKind
    let groundTruthVisible: Bool
    let predictedVisible: Bool
}

struct TechniqueRatingEvaluation: Sendable {
    let label: CoachTechniqueLabel
    let groundTruthRating: Int
    let predictedRating: Int
}

struct PriorityEvaluation: Sendable {
    let groundTruth: CoachTechniqueLabel
    let predicted: CoachTechniqueLabel
}

struct RepeatabilityEvaluation: Sendable {
    let firstScore: Int
    let repeatedScore: Int
}

enum EvaluationSubgroupDimension: String, CaseIterable, Sendable {
    case cameraAngle
    case skillGroup
    case handedness
    case lighting
    case resolution
    case frameRate
}

struct ModelEvaluationDesign: Sendable {
    let uniquePlayerCount: Int
    let usesPlayerHeldOutSplit: Bool
    let allClipsHaveTrainingConsent: Bool
    let provenanceVerified: Bool
    let auditedSubgroupDimensions: Set<EvaluationSubgroupDimension>
    let failedMaterialSubgroups: [String]

    static let unverified = ModelEvaluationDesign(
        uniquePlayerCount: 0,
        usesPlayerHeldOutSplit: false,
        allClipsHaveTrainingConsent: false,
        provenanceVerified: false,
        auditedSubgroupDimensions: [],
        failedMaterialSubgroups: []
    )
}

struct AccuracyAcceptanceCriteria: Sendable {
    var minimumHeldOutClipCount = 60
    var minimumHeldOutPlayerCount = 10
    var minimumQualityPrecision = 0.90
    var minimumQualityRecall = 0.90
    var maximumBoundaryMeanAbsoluteError = 0.12
    var minimumPhaseVisibilityF1 = 0.85
    var maximumTechniqueRatingMeanAbsoluteError = 0.60
    var minimumPriorityAgreement = 0.75
    var minimumRepeatabilityWithinFivePoints = 0.90
}

struct ModelEvaluationReport: Sendable {
    let clipCount: Int
    let evaluationDesign: ModelEvaluationDesign
    let qualityPrecision: Double
    let qualityRecall: Double
    let qualityF1: Double
    let boundaryMeanAbsoluteError: TimeInterval
    let phaseVisibilityPrecision: Double
    let phaseVisibilityRecall: Double
    let phaseVisibilityF1: Double
    let techniqueRatingMeanAbsoluteError: Double
    let priorityAgreement: Double
    let repeatabilityWithinFivePoints: Double

    func failedCriteria(_ criteria: AccuracyAcceptanceCriteria = AccuracyAcceptanceCriteria()) -> [String] {
        var failures: [String] = []
        if clipCount < criteria.minimumHeldOutClipCount { failures.append("held-out clip count") }
        if evaluationDesign.uniquePlayerCount < criteria.minimumHeldOutPlayerCount { failures.append("held-out player count") }
        if !evaluationDesign.usesPlayerHeldOutSplit { failures.append("player-held-out split") }
        if !evaluationDesign.allClipsHaveTrainingConsent { failures.append("training consent verification") }
        if !evaluationDesign.provenanceVerified { failures.append("dataset provenance verification") }
        let missingDimensions = Set(EvaluationSubgroupDimension.allCases)
            .subtracting(evaluationDesign.auditedSubgroupDimensions)
        if !missingDimensions.isEmpty { failures.append("subgroup coverage") }
        if !evaluationDesign.failedMaterialSubgroups.isEmpty { failures.append("subgroup performance") }
        if qualityPrecision < criteria.minimumQualityPrecision { failures.append("recording-quality precision") }
        if qualityRecall < criteria.minimumQualityRecall { failures.append("recording-quality recall") }
        if boundaryMeanAbsoluteError > criteria.maximumBoundaryMeanAbsoluteError { failures.append("phase-boundary timing") }
        if phaseVisibilityF1 < criteria.minimumPhaseVisibilityF1 { failures.append("phase visibility") }
        if techniqueRatingMeanAbsoluteError > criteria.maximumTechniqueRatingMeanAbsoluteError { failures.append("technique rating agreement") }
        if priorityAgreement < criteria.minimumPriorityAgreement { failures.append("coach priority agreement") }
        if repeatabilityWithinFivePoints < criteria.minimumRepeatabilityWithinFivePoints { failures.append("repeatability") }
        return failures
    }

    var passes: Bool { failedCriteria().isEmpty }
}

struct ServeModelEvaluator: Sendable {
    func evaluate(
        quality: [BinaryQualityEvaluation],
        boundaries: [PhaseBoundaryEvaluation],
        phaseVisibility: [PhaseVisibilityEvaluation],
        techniqueRatings: [TechniqueRatingEvaluation],
        priorities: [PriorityEvaluation],
        repeatability: [RepeatabilityEvaluation],
        design: ModelEvaluationDesign
    ) -> ModelEvaluationReport {
        let truePositive = quality.filter { $0.groundTruthUsable && $0.predictedUsable }.count
        let falsePositive = quality.filter { !$0.groundTruthUsable && $0.predictedUsable }.count
        let falseNegative = quality.filter { $0.groundTruthUsable && !$0.predictedUsable }.count
        let precision = ratio(truePositive, truePositive + falsePositive)
        let recall = ratio(truePositive, truePositive + falseNegative)
        let f1 = (precision + recall) > 0 ? (2 * precision * recall / (precision + recall)) : 0

        let boundaryErrors = boundaries.flatMap {
            [abs($0.predictedStart - $0.groundTruthStart), abs($0.predictedEnd - $0.groundTruthEnd)]
        }
        let boundaryMAE = boundaryErrors.isEmpty ? .infinity : boundaryErrors.reduce(0, +) / Double(boundaryErrors.count)
        let visibleTruePositive = phaseVisibility.filter { $0.groundTruthVisible && $0.predictedVisible }.count
        let visibleFalsePositive = phaseVisibility.filter { !$0.groundTruthVisible && $0.predictedVisible }.count
        let visibleFalseNegative = phaseVisibility.filter { $0.groundTruthVisible && !$0.predictedVisible }.count
        let visibilityPrecision = ratio(visibleTruePositive, visibleTruePositive + visibleFalsePositive)
        let visibilityRecall = ratio(visibleTruePositive, visibleTruePositive + visibleFalseNegative)
        let visibilityF1 = (visibilityPrecision + visibilityRecall) > 0
            ? 2 * visibilityPrecision * visibilityRecall / (visibilityPrecision + visibilityRecall)
            : 0
        let ratingErrors = techniqueRatings.map {
            abs(Double($0.predictedRating - $0.groundTruthRating))
        }
        let ratingMAE = ratingErrors.isEmpty ? .infinity : ratingErrors.reduce(0, +) / Double(ratingErrors.count)
        let priorityAgreement = ratio(
            priorities.filter { $0.groundTruth == $0.predicted }.count,
            priorities.count
        )
        let repeatabilityRate = ratio(
            repeatability.filter { abs($0.firstScore - $0.repeatedScore) <= 5 }.count,
            repeatability.count
        )

        return ModelEvaluationReport(
            clipCount: quality.count,
            evaluationDesign: design,
            qualityPrecision: precision,
            qualityRecall: recall,
            qualityF1: f1,
            boundaryMeanAbsoluteError: boundaryMAE,
            phaseVisibilityPrecision: visibilityPrecision,
            phaseVisibilityRecall: visibilityRecall,
            phaseVisibilityF1: visibilityF1,
            techniqueRatingMeanAbsoluteError: ratingMAE,
            priorityAgreement: priorityAgreement,
            repeatabilityWithinFivePoints: repeatabilityRate
        )
    }

    private func ratio(_ numerator: Int, _ denominator: Int) -> Double {
        denominator > 0 ? Double(numerator) / Double(denominator) : 0
    }
}
