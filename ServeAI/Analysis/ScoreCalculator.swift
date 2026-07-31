import Foundation

struct ScoreCalculator: Sendable {
    // Nil and low-confidence phases are removed and the remaining weights are
    // normalized. A speculative 2D proxy must not move the overall score as much as
    // a stable, clearly tracked observation.
    private let phaseWeights: [ServePhaseKind: Double] = [
        .startingStance: 0.05,
        .ballToss: 0.20,
        .loading: 0.10,
        .trophyPosition: 0.10,
        .legDrive: 0.15,
        .racketDrop: 0.075,
        .upwardAcceleration: 0.075,
        .contactPosition: 0.20,
        .pronation: 0.05,
        .landingFollowThrough: 0.05
    ]

    func weightedScore(for phases: [PhaseScore]) -> Int? {
        let measurable = phases.compactMap { item -> (Int, Double)? in
            guard let score = item.score, let weight = phaseWeights[item.phase] else { return nil }
            let confidenceWeight: Double = switch item.confidence {
            case .high: 1.0
            case .medium: 0.70
            case .low: 0
            }
            guard confidenceWeight > 0 else { return nil }
            return (max(0, min(100, score)), weight * confidenceWeight)
        }
        let totalWeight = measurable.reduce(0) { $0 + $1.1 }
        guard totalWeight > 0 else { return nil }
        let total = measurable.reduce(0) { $0 + Double($1.0) * $1.1 }
        return Int((total / totalWeight).rounded())
    }
}
