import Foundation

#if DEBUG
// A Debug-only, single-object association experiment. It never invents a box in a
// missed frame and does not turn a detector observation into a technique score.
struct ObjectDetectionCandidate: Equatable, Sendable {
    let label: String
    let confidence: Double
    let xmin: Double
    let xmax: Double
    let ymin: Double
    let ymax: Double

    var centerX: Double { (xmin + xmax) / 2 }
    var centerY: Double { (ymin + ymax) / 2 }

    var isValid: Bool {
        confidence.isFinite && (0...1).contains(confidence)
            && [xmin, xmax, ymin, ymax].allSatisfy { $0.isFinite && (0...1).contains($0) }
            && xmin < xmax && ymin < ymax
    }
}

struct ObjectDetectionSelection: Equatable, Sendable {
    let frameIndex: Int
    let candidate: ObjectDetectionCandidate
    let linkedToPrevious: Bool
}

enum ObjectDetectionSequenceSelector {
    // A skipped frame is tolerated, but a longer gap cannot establish continuity.
    static let maximumFrameGap = 2
    static let maximumNormalizedDisplacementPerFrame = 0.18
    static let continuityBonus = 0.10

    static func select(
        frames: [[ObjectDetectionCandidate]],
        label: String,
        minimumConfidence: Double
    ) -> [ObjectDetectionSelection] {
        var selections: [ObjectDetectionSelection] = []
        for (frameIndex, candidates) in frames.enumerated() {
            let eligible = candidates.filter {
                $0.label == label && $0.isValid && $0.confidence >= minimumConfidence
            }
            guard !eligible.isEmpty else { continue }

            let previous = selections.last
            let gap = previous.map { frameIndex - $0.frameIndex } ?? 0
            let canLink = previous != nil && gap <= maximumFrameGap
            var best: ObjectDetectionCandidate?
            var bestScore = -Double.infinity
            var bestLinked = false
            for candidate in eligible {
                let displacement = previous.map {
                    hypot(candidate.centerX - $0.candidate.centerX, candidate.centerY - $0.candidate.centerY)
                } ?? .infinity
                let maximumDisplacement = maximumNormalizedDisplacementPerFrame * Double(gap)
                let linked = canLink && displacement <= maximumDisplacement
                let score = candidate.confidence + (linked
                    ? continuityBonus * (1 - displacement / maximumDisplacement)
                    : 0)
                if score > bestScore {
                    best = candidate
                    bestScore = score
                    bestLinked = linked
                }
            }
            if let best {
                selections.append(ObjectDetectionSelection(
                    frameIndex: frameIndex,
                    candidate: best,
                    linkedToPrevious: bestLinked
                ))
            }
        }
        return selections
    }
}
#endif
