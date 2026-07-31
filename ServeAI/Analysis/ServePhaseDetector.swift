import Foundation

protocol ServePhaseDetecting: Sendable {
    func detect(in frames: [PoseFrame]) -> [DetectedServePhase]
}

struct HeuristicServePhaseDetector: ServePhaseDetecting {
    private enum ArmSide {
        case left
        case right
    }

    func detect(in frames: [PoseFrame]) -> [DetectedServePhase] {
        guard frames.count >= 10 else { return [] }

        // TODO(ML): Replace these event heuristics with a validated tennis phase model.
        // This first-pass detector anchors a chronological template to observable joint
        // extrema. It is deliberately isolated behind ServePhaseDetecting so a trained
        // Core ML or server model can replace it without changing reports or persistence.
        let lastIndex = frames.count - 1
        let hittingArm = inferredHittingArm(in: frames)
        let tossArm = hittingArm.map(opposite)
        let tossPeak = highestWristIndex(in: frames, lower: 0, upper: max(2, frames.count / 2), arm: tossArm) ?? frames.count * 3 / 10
        let loadingLow = lowestRootIndex(in: frames, lower: frames.count / 8, upper: max(frames.count / 4, frames.count * 6 / 10)) ?? frames.count * 4 / 10
        let racketDrop = lowestWristIndex(in: frames, lower: frames.count * 3 / 10, upper: max(frames.count / 2, frames.count * 8 / 10), arm: hittingArm) ?? frames.count * 6 / 10
        let contact = highestWristIndex(in: frames, lower: frames.count / 2, upper: frames.count, arm: hittingArm) ?? frames.count * 8 / 10

        var raw = [
            0,
            max(1, tossPeak / 2),
            tossPeak,
            max(tossPeak, loadingLow),
            max(loadingLow, frames.count / 2),
            max(racketDrop, frames.count / 2),
            max(racketDrop + 1, frames.count * 7 / 10),
            max(contact, frames.count * 7 / 10),
            frames.count * 9 / 10,
            lastIndex,
            lastIndex
        ]
        var previous = 0
        for index in raw.indices {
            raw[index] = min(lastIndex, max(previous, raw[index]))
            previous = raw[index]
        }

        var detected: [DetectedServePhase] = []
        for phaseIndex in 0..<ServePhaseKind.allCases.count {
            let phase = ServePhaseKind.allCases[phaseIndex]
            let startIndex = raw[phaseIndex]
            let endIndex = raw[phaseIndex + 1]
            let confidence = averageConfidence(in: frames, lower: startIndex, upper: endIndex)
            detected.append(DetectedServePhase(phase: phase, startTime: frames[startIndex].timestamp, endTime: frames[endIndex].timestamp, confidence: confidence))
        }
        return detected
    }

    private func highestWristIndex(in frames: [PoseFrame], lower: Int, upper: Int, arm: ArmSide?) -> Int? {
        wristExtremeIndex(in: frames, lower: lower, upper: upper, findMaximum: true, arm: arm)
    }

    private func lowestWristIndex(in frames: [PoseFrame], lower: Int, upper: Int, arm: ArmSide?) -> Int? {
        wristExtremeIndex(in: frames, lower: lower, upper: upper, findMaximum: false, arm: arm)
    }

    private func wristExtremeIndex(in frames: [PoseFrame], lower: Int, upper: Int, findMaximum: Bool, arm: ArmSide?) -> Int? {
        let start = max(0, lower)
        let end = min(frames.count, max(start, upper))
        var selectedIndex: Int?
        var selectedValue = findMaximum ? -Double.greatestFiniteMagnitude : Double.greatestFiniteMagnitude
        guard start < end else { return nil }
        for index in start..<end {
            let point: PosePoint?
            if let arm {
                point = frames[index].joints[wristJoint(for: arm)]
            } else {
                let left = frames[index].joints[.leftWrist]
                let right = frames[index].joints[.rightWrist]
                if let left, let right { point = left.confidence >= right.confidence ? left : right }
                else { point = left ?? right }
            }
            guard let point, point.confidence >= 0.25 else { continue }
            let improves = findMaximum ? point.y > selectedValue : point.y < selectedValue
            if improves {
                selectedValue = point.y
                selectedIndex = index
            }
        }
        return selectedIndex
    }

    private func inferredHittingArm(in frames: [PoseFrame]) -> ArmSide? {
        let candidates = Array(frames.suffix(max(3, frames.count / 2)))
        let left = hittingArmScore(in: candidates, arm: .left)
        let right = hittingArmScore(in: candidates, arm: .right)
        switch (left, right) {
        case let (left?, right?): return left >= right ? .left : .right
        case (.some, .none): return .left
        case (.none, .some): return .right
        case (.none, .none): return nil
        }
    }

    private func hittingArmScore(in frames: [PoseFrame], arm: ArmSide) -> Double? {
        let joint = wristJoint(for: arm)
        let shoulderJoint: BodyJoint = arm == .left ? .leftShoulder : .rightShoulder
        let samples = frames.compactMap { frame -> (height: Double, confidence: Double)? in
            guard let wrist = frame.joints[joint], wrist.confidence >= 0.25 else { return nil }
            let height: Double
            if let shoulder = frame.joints[shoulderJoint],
               let neck = frame.joints[.neck],
               let root = frame.joints[.root] {
                let scale = Geometry.distance(neck.point, root.point)
                height = scale > 0.04 ? (wrist.y - shoulder.y) / scale : wrist.y
            } else {
                height = wrist.y
            }
            return (height, wrist.confidence)
        }
        guard samples.count >= 2 else { return nil }
        let half = max(1, samples.count / 2)
        let early = Array(samples.prefix(half))
        let late = Array(samples.suffix(half))
        guard let low = Geometry.robustPercentile(early.map(\.height), 0.20),
              let peak = Geometry.robustPercentile(late.map(\.height), 0.80) else {
            return nil
        }
        let upwardRange = max(0, peak - low)
        let coverage = Double(samples.count) / Double(max(frames.count, 1))
        let confidence = samples.map(\.confidence).reduce(0, +) / Double(samples.count)
        return min(1.5, upwardRange) / 1.5 * 0.65
            + max(0, min(1.5, peak)) / 1.5 * 0.15
            + coverage * 0.10
            + confidence * 0.10
    }

    private func wristJoint(for arm: ArmSide) -> BodyJoint {
        arm == .left ? .leftWrist : .rightWrist
    }

    private func opposite(of arm: ArmSide) -> ArmSide {
        arm == .left ? .right : .left
    }

    private func lowestRootIndex(in frames: [PoseFrame], lower: Int, upper: Int) -> Int? {
        let start = max(0, lower)
        let end = min(frames.count, max(start, upper))
        var selectedIndex: Int?
        var selectedValue = Double.greatestFiniteMagnitude
        guard start < end else { return nil }
        for index in start..<end {
            guard let root = frames[index].joints[.root], root.confidence >= 0.25 else { continue }
            if root.y < selectedValue {
                selectedValue = root.y
                selectedIndex = index
            }
        }
        return selectedIndex
    }

    private func averageConfidence(in frames: [PoseFrame], lower: Int, upper: Int) -> Double {
        let end = max(lower, min(frames.count - 1, upper))
        var total = 0.0
        var count = 0
        for index in lower...end {
            total += frames[index].bodyConfidence
            count += 1
        }
        return count > 0 ? total / Double(count) : 0
    }
}
