import Foundation

protocol ServePhaseDetecting: Sendable {
    func detect(in frames: [PoseFrame]) -> [DetectedServePhase]
}

struct HeuristicServePhaseDetector: ServePhaseDetecting {
    func detect(in frames: [PoseFrame]) -> [DetectedServePhase] {
        guard frames.count >= 10 else { return [] }

        // TODO(ML): Replace these event heuristics with a validated tennis phase model.
        // This first-pass detector anchors a chronological template to observable joint
        // extrema. It is deliberately isolated behind ServePhaseDetecting so a trained
        // Core ML or server model can replace it without changing reports or persistence.
        let lastIndex = frames.count - 1
        let tossPeak = highestWristIndex(in: frames, lower: 0, upper: max(2, frames.count / 2)) ?? frames.count * 3 / 10
        let loadingLow = lowestRootIndex(in: frames, lower: frames.count / 8, upper: max(frames.count / 4, frames.count * 6 / 10)) ?? frames.count * 4 / 10
        let racketDrop = lowestWristIndex(in: frames, lower: frames.count * 3 / 10, upper: max(frames.count / 2, frames.count * 8 / 10)) ?? frames.count * 6 / 10
        let contact = highestWristIndex(in: frames, lower: frames.count / 2, upper: frames.count) ?? frames.count * 8 / 10

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

    private func highestWristIndex(in frames: [PoseFrame], lower: Int, upper: Int) -> Int? {
        wristExtremeIndex(in: frames, lower: lower, upper: upper, findMaximum: true)
    }

    private func lowestWristIndex(in frames: [PoseFrame], lower: Int, upper: Int) -> Int? {
        wristExtremeIndex(in: frames, lower: lower, upper: upper, findMaximum: false)
    }

    private func wristExtremeIndex(in frames: [PoseFrame], lower: Int, upper: Int, findMaximum: Bool) -> Int? {
        let start = max(0, lower)
        let end = min(frames.count, max(start, upper))
        var selectedIndex: Int?
        var selectedValue = findMaximum ? -Double.greatestFiniteMagnitude : Double.greatestFiniteMagnitude
        guard start < end else { return nil }
        for index in start..<end {
            let left = frames[index].joints[.leftWrist]
            let right = frames[index].joints[.rightWrist]
            var point: PosePoint?
            if let left, let right { point = left.confidence >= right.confidence ? left : right }
            else { point = left ?? right }
            guard let point, point.confidence >= 0.25 else { continue }
            let improves = findMaximum ? point.y > selectedValue : point.y < selectedValue
            if improves {
                selectedValue = point.y
                selectedIndex = index
            }
        }
        return selectedIndex
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
