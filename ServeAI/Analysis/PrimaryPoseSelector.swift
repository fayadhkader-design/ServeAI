import Foundation

struct PrimaryPoseSelectionPolicy: Sendable {
    var minimumJointConfidence = 0.25
    var minimumJointCount = 6
    var comparableHeightRatio = 0.72
    var comparableAreaRatio = 0.42
    var comparableScoreRatio = 0.72
}

enum PrimaryPoseSelection: Sendable {
    case none
    case selected(PoseFrame)
    case ambiguous
}

struct PrimaryPoseSelector: Sendable {
    let policy: PrimaryPoseSelectionPolicy

    init(policy: PrimaryPoseSelectionPolicy = PrimaryPoseSelectionPolicy()) {
        self.policy = policy
    }

    func select(from candidates: [PoseFrame]) -> PrimaryPoseSelection {
        let ranked = candidates
            .compactMap { candidate in
                PoseCandidate(frame: candidate, policy: policy)
            }
            .sorted { lhs, rhs in
                if lhs.dominanceScore == rhs.dominanceScore {
                    return lhs.frame.id.uuidString < rhs.frame.id.uuidString
                }
                return lhs.dominanceScore > rhs.dominanceScore
            }

        guard let primary = ranked.first else { return .none }
        guard ranked.count > 1 else { return .selected(primary.frame) }

        let competingCandidate = ranked.dropFirst().contains { candidate in
            isComparable(candidate, to: primary)
        }
        return competingCandidate ? .ambiguous : .selected(primary.frame)
    }

    private func isComparable(_ candidate: PoseCandidate, to primary: PoseCandidate) -> Bool {
        guard primary.height > 0, primary.area > 0, primary.dominanceScore > 0 else {
            return false
        }

        let heightRatio = candidate.height / primary.height
        let areaRatio = candidate.area / primary.area
        let scoreRatio = candidate.dominanceScore / primary.dominanceScore
        return heightRatio >= policy.comparableHeightRatio
            && (
                areaRatio >= policy.comparableAreaRatio
                    || scoreRatio >= policy.comparableScoreRatio
            )
    }
}

private struct PoseCandidate {
    let frame: PoseFrame
    let width: Double
    let height: Double
    let area: Double
    let dominanceScore: Double

    init?(frame: PoseFrame, policy: PrimaryPoseSelectionPolicy) {
        let visible = frame.joints.values.filter {
            $0.confidence >= policy.minimumJointConfidence
        }
        guard visible.count >= policy.minimumJointCount,
              let minimumX = visible.map(\.x).min(),
              let maximumX = visible.map(\.x).max(),
              let minimumY = visible.map(\.y).min(),
              let maximumY = visible.map(\.y).max() else {
            return nil
        }

        let width = max(0, maximumX - minimumX)
        let height = max(0, maximumY - minimumY)
        guard width > 0, height > 0 else { return nil }

        let area = width * height
        let jointCoverage = Double(visible.count) / Double(BodyJoint.allCases.count)
        let geometricScale = height * 0.68 + area.squareRoot() * 0.27
        let confidenceWeight = 0.85 + min(max(frame.bodyConfidence, 0), 1) * 0.15

        self.frame = frame
        self.width = width
        self.height = height
        self.area = area
        dominanceScore = geometricScale * confidenceWeight + jointCoverage * 0.05
    }
}
