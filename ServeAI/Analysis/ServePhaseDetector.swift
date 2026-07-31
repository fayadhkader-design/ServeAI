import Foundation

protocol ServePhaseDetecting: Sendable {
    func detect(in frames: [PoseFrame]) -> [DetectedServePhase]
}

struct HeuristicServePhaseDetector: ServePhaseDetecting {
    private enum ArmSide {
        case left
        case right
    }

    private struct TrajectorySample {
        let index: Int
        let value: Double
        let confidence: Double
    }

    private struct Trajectory {
        let samples: [TrajectorySample]
        let isTorsoNormalized: Bool
    }

    private struct EventAnchor {
        let index: Int
        let confidence: Double
    }

    private struct PhaseBoundary {
        var index: Int
        let confidence: Double
    }

    func detect(in frames: [PoseFrame]) -> [DetectedServePhase] {
        guard frames.count >= 10 else { return [] }

        // Published serve definitions use ball release, trophy/loading, racket low
        // point, and impact as key events. Body pose cannot observe the ball or
        // racket, so these are deliberately body-joint proxies. Missing proxies
        // retain a chronological display interval but receive zero event confidence;
        // downstream scoring must not treat that interval as measured evidence.
        let lastIndex = frames.count - 1
        let hittingArm = inferredHittingArm(in: frames)
        let tossArm = hittingArm.map(opposite)

        let tossSearch = boundedRange(
            lower: frames.count / 20,
            upper: frames.count * 11 / 20,
            count: frames.count
        )
        let tossTrajectory = wristHeightTrajectory(in: frames, arm: tossArm)
        let tossPeak = robustExtremeAnchor(
            in: tossTrajectory.samples,
            range: tossSearch,
            findMaximum: true,
            minimumProminence: tossTrajectory.isTorsoNormalized ? 0.20 : 0.07
        )

        let loadSearch = boundedRange(
            lower: max(frames.count / 10, tossPeak?.index ?? 0),
            upper: frames.count * 7 / 10,
            count: frames.count
        )
        let rootTrajectory = bodyCenterHeightTrajectory(in: frames)
        let loadingLow = robustExtremeAnchor(
            in: rootTrajectory.samples,
            range: loadSearch,
            findMaximum: false,
            minimumProminence: rootTrajectory.isTorsoNormalized ? 0.08 : 0.025
        )

        let hittingWristTrajectory = wristHeightTrajectory(in: frames, arm: hittingArm)
        let contactSearch = boundedRange(
            lower: max(frames.count / 2, loadingLow?.index ?? frames.count / 2),
            upper: frames.count * 19 / 20,
            count: frames.count
        )
        let likelyContact = robustExtremeAnchor(
            in: hittingWristTrajectory.samples,
            range: contactSearch,
            findMaximum: true,
            minimumProminence: hittingWristTrajectory.isTorsoNormalized ? 0.22 : 0.07
        )
        let dropSearch = boundedRange(
            lower: max(frames.count * 3 / 10, loadingLow?.index ?? 0),
            upper: min(
                frames.count * 17 / 20,
                likelyContact?.index ?? frames.count * 17 / 20
            ),
            count: frames.count
        )
        let racketDrop = robustExtremeAnchor(
            in: hittingWristTrajectory.samples,
            range: dropSearch,
            findMaximum: false,
            minimumProminence: hittingWristTrajectory.isTorsoNormalized ? 0.18 : 0.06
        )

        let bodyConfidence = frames.map(\.bodyConfidence).reduce(0, +)
            / Double(frames.count)
        let fallbackToss = frames.count * 3 / 10
        let fallbackLoad = frames.count * 9 / 20
        let fallbackDrop = frames.count * 13 / 20
        let fallbackContact = frames.count * 4 / 5
        let toss = tossPeak ?? EventAnchor(index: fallbackToss, confidence: 0)
        let load = loadingLow ?? EventAnchor(index: fallbackLoad, confidence: 0)
        let contact = likelyContact ?? EventAnchor(index: fallbackContact, confidence: 0)
        let derivedDrop = EventAnchor(
            index: midpoint(load.index, contact.index),
            confidence: min(load.confidence, contact.confidence) * 0.65
        )
        let drop = racketDrop ?? (
            derivedDrop.confidence > 0
                ? derivedDrop
                : EventAnchor(index: fallbackDrop, confidence: 0)
        )

        var boundaries = [
            PhaseBoundary(index: 0, confidence: bodyConfidence),
            PhaseBoundary(index: max(1, toss.index / 2), confidence: toss.confidence * 0.80),
            PhaseBoundary(index: toss.index, confidence: toss.confidence),
            PhaseBoundary(index: load.index, confidence: load.confidence),
            PhaseBoundary(
                index: midpoint(load.index, drop.index),
                confidence: min(load.confidence, drop.confidence)
            ),
            PhaseBoundary(index: drop.index, confidence: drop.confidence),
            PhaseBoundary(
                index: midpoint(drop.index, contact.index),
                confidence: min(drop.confidence, contact.confidence)
            ),
            PhaseBoundary(index: contact.index, confidence: contact.confidence),
            PhaseBoundary(
                index: min(lastIndex, contact.index + max(1, frames.count / 20)),
                confidence: contact.confidence * 0.80
            ),
            PhaseBoundary(
                index: max(contact.index, frames.count * 9 / 10),
                confidence: contact.confidence * 0.65
            ),
            PhaseBoundary(index: lastIndex, confidence: bodyConfidence)
        ]

        var previous = 0
        for index in boundaries.indices {
            boundaries[index].index = min(lastIndex, max(previous, boundaries[index].index))
            previous = boundaries[index].index
        }

        return ServePhaseKind.allCases.enumerated().map { phaseIndex, phase in
            let lower = boundaries[phaseIndex]
            let upper = boundaries[phaseIndex + 1]
            let poseConfidence = averageConfidence(
                in: frames,
                lower: lower.index,
                upper: upper.index
            )
            let eventConfidence = min(lower.confidence, upper.confidence)
            let confidence = eventConfidence * 0.70 + poseConfidence * 0.30
            return DetectedServePhase(
                phase: phase,
                startTime: frames[lower.index].timestamp,
                endTime: frames[upper.index].timestamp,
                confidence: max(0, min(1, confidence))
            )
        }
    }

    private func robustExtremeAnchor(
        in samples: [TrajectorySample],
        range: Range<Int>,
        findMaximum: Bool,
        minimumProminence: Double
    ) -> EventAnchor? {
        let selected = samples.filter { range.contains($0.index) }
        guard selected.count >= 4, range.count > 0 else { return nil }

        let smoothed = selected.compactMap { sample -> TrajectorySample? in
            let neighborhood = selected.filter { abs($0.index - sample.index) <= 2 }
            guard neighborhood.count >= 2,
                  let value = Geometry.percentile(neighborhood.map(\.value), 0.50) else {
                return nil
            }
            let confidence = neighborhood.map(\.confidence).reduce(0, +)
                / Double(neighborhood.count)
            return TrajectorySample(
                index: sample.index,
                value: value,
                confidence: confidence
            )
        }
        guard smoothed.count >= 3,
              let low = Geometry.robustPercentile(smoothed.map(\.value), 0.15),
              let high = Geometry.robustPercentile(smoothed.map(\.value), 0.85),
              high - low >= minimumProminence,
              let anchor = smoothed.max(by: {
                  findMaximum ? $0.value < $1.value : $0.value > $1.value
              }) else {
            return nil
        }

        let coverage = min(1, Double(selected.count) / Double(range.count))
        let prominenceQuality = min(1, (high - low) / max(minimumProminence * 1.5, 0.001))
        let confidence = anchor.confidence * 0.65
            + coverage * 0.20
            + prominenceQuality * 0.15
        return EventAnchor(index: anchor.index, confidence: min(1, confidence))
    }

    private func wristHeightTrajectory(
        in frames: [PoseFrame],
        arm: ArmSide?
    ) -> Trajectory {
        guard let arm else { return Trajectory(samples: [], isTorsoNormalized: false) }
        let wristJoint = wristJoint(for: arm)
        let shoulderJoint: BodyJoint = arm == .left ? .leftShoulder : .rightShoulder
        let normalized = frames.enumerated().compactMap { index, frame -> TrajectorySample? in
            guard let wrist = frame.joints[wristJoint],
                  let shoulder = frame.joints[shoulderJoint],
                  let scale = torsoScale(in: frame),
                  scale > 0.04 else {
                return nil
            }
            let confidence = min(wrist.confidence, shoulder.confidence)
            guard confidence >= 0.25 else { return nil }
            return TrajectorySample(
                index: index,
                value: (wrist.y - shoulder.y) / scale,
                confidence: confidence
            )
        }
        if normalized.count >= 4 {
            return Trajectory(samples: normalized, isTorsoNormalized: true)
        }

        let raw = frames.enumerated().compactMap { index, frame -> TrajectorySample? in
            guard let wrist = frame.joints[wristJoint], wrist.confidence >= 0.25 else {
                return nil
            }
            return TrajectorySample(
                index: index,
                value: wrist.y,
                confidence: wrist.confidence * 0.65
            )
        }
        return Trajectory(samples: raw, isTorsoNormalized: false)
    }

    private func bodyCenterHeightTrajectory(in frames: [PoseFrame]) -> Trajectory {
        let normalized = frames.enumerated().compactMap { index, frame -> TrajectorySample? in
            guard let root = frame.joints[.root],
                  let scale = torsoScale(in: frame),
                  scale > 0.04 else {
                return nil
            }
            let ankles = [frame.joints[.leftAnkle], frame.joints[.rightAnkle]]
                .compactMap { $0 }
                .filter { $0.confidence >= 0.25 }
            guard !ankles.isEmpty else { return nil }
            let ankleY = ankles.map(\.y).reduce(0, +) / Double(ankles.count)
            let confidence = min(root.confidence, ankles.map(\.confidence).max() ?? 0)
            return TrajectorySample(
                index: index,
                value: (root.y - ankleY) / scale,
                confidence: confidence
            )
        }
        if normalized.count >= 4 {
            return Trajectory(samples: normalized, isTorsoNormalized: true)
        }

        let raw = frames.enumerated().compactMap { index, frame -> TrajectorySample? in
            guard let root = frame.joints[.root], root.confidence >= 0.25 else {
                return nil
            }
            return TrajectorySample(
                index: index,
                value: root.y,
                confidence: root.confidence * 0.65
            )
        }
        return Trajectory(samples: raw, isTorsoNormalized: false)
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
               let scale = torsoScale(in: frame),
               scale > 0.04 {
                height = (wrist.y - shoulder.y) / scale
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

    private func torsoScale(in frame: PoseFrame) -> Double? {
        if let neck = frame.joints[.neck], let root = frame.joints[.root] {
            return Geometry.distance(neck.point, root.point)
        }
        if let left = frame.joints[.leftShoulder],
           let right = frame.joints[.rightShoulder] {
            return Geometry.distance(left.point, right.point) * 1.5
        }
        return nil
    }

    private func wristJoint(for arm: ArmSide) -> BodyJoint {
        arm == .left ? .leftWrist : .rightWrist
    }

    private func opposite(of arm: ArmSide) -> ArmSide {
        arm == .left ? .right : .left
    }

    private func midpoint(_ first: Int, _ second: Int) -> Int {
        first + max(0, second - first) / 2
    }

    private func boundedRange(lower: Int, upper: Int, count: Int) -> Range<Int> {
        let start = max(0, min(count - 1, lower))
        let end = max(start + 1, min(count, upper))
        return start..<end
    }

    private func averageConfidence(
        in frames: [PoseFrame],
        lower: Int,
        upper: Int
    ) -> Double {
        let start = max(0, min(frames.count - 1, lower))
        let end = max(start, min(frames.count - 1, upper))
        let values = frames[start...end].map(\.bodyConfidence)
        return values.reduce(0, +) / Double(max(values.count, 1))
    }
}
