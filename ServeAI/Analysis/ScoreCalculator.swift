import Foundation

struct ScoreCalculator: Sendable {
    // The weights mirror the coaching categories in the product brief. Nil phases are
    // removed and the remaining weights are normalized, so poor visibility is not a penalty.
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
            return (max(0, min(100, score)), weight)
        }
        let totalWeight = measurable.reduce(0) { $0 + $1.1 }
        guard totalWeight > 0 else { return nil }
        let total = measurable.reduce(0) { $0 + Double($1.0) * $1.1 }
        return Int((total / totalWeight).rounded())
    }
}
