import Foundation

struct HeuristicPhaseScorer: Sendable {
    // TODO(ML): Calibrate scoring ranges against expert-labeled serves before production use.
    func score(frames: [PoseFrame], phases: [DetectedServePhase]) -> [PhaseScore] {
        ServePhaseKind.allCases.map { phase in
            let phaseFrames = framesFor(phase, in: frames, phases: phases)
            guard !phaseFrames.isEmpty else {
                return PhaseScore(phase: phase, score: nil, confidence: .low, note: "Insufficient visibility — this phase could not be isolated.")
            }
            return score(phase, frames: phaseFrames)
        }
    }

    private func score(_ phase: ServePhaseKind, frames: [PoseFrame]) -> PhaseScore {
        let quality = frames.reduce(0) { $0 + $1.bodyConfidence } / Double(frames.count)
        let confidence = level(quality)
        guard quality >= 0.35 else {
            return PhaseScore(phase: phase, score: nil, confidence: .low, note: "Insufficient visibility — too few required joints were tracked.")
        }

        switch phase {
        case .startingStance:
            guard let frame = frames.first, let leftAnkle = frame.joints[.leftAnkle], let rightAnkle = frame.joints[.rightAnkle], let root = frame.joints[.root] else { return unavailable(phase, "Feet or hips were outside the frame.") }
            let lower = min(leftAnkle.x, rightAnkle.x), upper = max(leftAnkle.x, rightAnkle.x)
            let centered = root.x >= lower && root.x <= upper
            return PhaseScore(phase: phase, score: centered ? 82 : 62, confidence: confidence, note: centered ? "The hip center begins over the base of support." : "The hip center begins outside the visible base of support.")
        case .ballToss:
            let peak = frames.flatMap { [$0.joints[.leftWrist], $0.joints[.rightWrist]].compactMap { $0 } }.max { $0.y < $1.y }
            guard let peak else { return unavailable(phase, "The tossing wrist was not visible.") }
            let score = Int(max(50, min(90, 55 + peak.y * 40)))
            return PhaseScore(phase: phase, score: score, confidence: confidence, note: peak.y > 0.80 ? "The visible wrist reaches full overhead extension." : "The visible wrist peaks below the expected overhead range.")
        case .loading:
            let angles = frames.compactMap(kneeAngle).filter { $0 > 40 && $0 < 180 }
            guard let minimum = angles.min() else { return unavailable(phase, "The hips, knees, and ankles were not visible together.") }
            let score = Int(max(50, 92 - abs(minimum - 110) * 0.7))
            return PhaseScore(phase: phase, score: score, confidence: confidence, note: "Deepest visible knee angle is approximately \(Int(minimum.rounded()))°.")
        case .trophyPosition:
            guard let best = frames.max(by: { abs(shoulderTilt($0) ?? 0) < abs(shoulderTilt($1) ?? 0) }), let tilt = shoulderTilt(best) else { return unavailable(phase, "Both shoulders were not tracked together.") }
            let score = Int(max(50, 92 - abs(abs(tilt) - 22) * 1.2))
            return PhaseScore(phase: phase, score: score, confidence: confidence, note: "Peak visible shoulder-line tilt is approximately \(Int(abs(tilt).rounded()))°.")
        case .legDrive:
            guard let first = frames.first?.joints[.root], let last = frames.last?.joints[.root] else { return unavailable(phase, "The body center was not tracked through the drive.") }
            let rise = last.y - first.y
            let score = Int(max(45, min(92, 65 + rise * 180)))
            return PhaseScore(phase: phase, score: score, confidence: confidence, note: rise > 0.05 ? "The body center rises during the drive." : "Limited upward body-center movement was visible.")
        case .racketDrop:
            return unavailable(phase, "Body pose does not identify the racket head; wrist position alone is not enough.")
        case .upwardAcceleration:
            let speeds = wristVerticalSpeeds(frames)
            guard let peak = speeds.max() else { return unavailable(phase, "The hitting wrist was not tracked continuously.") }
            let score = Int(max(50, min(90, 58 + peak * 12)))
            return PhaseScore(phase: phase, score: score, confidence: confidence, note: "The visible wrist gains upward speed before its highest point.")
        case .contactPosition:
            let extensions = frames.compactMap(elbowAngle)
            guard let maximum = extensions.max() else { return unavailable(phase, "Shoulder, elbow, and wrist were not visible together.") }
            let score = Int(max(50, min(94, 55 + (maximum - 120) * 0.8)))
            return PhaseScore(phase: phase, score: score, confidence: confidence, note: "Maximum visible hitting-arm extension is approximately \(Int(maximum.rounded()))°.")
        case .pronation:
            return unavailable(phase, "Forearm rotation cannot be resolved reliably from body joints alone.")
        case .landingFollowThrough:
            guard let final = frames.last, let root = final.joints[.root], let left = final.joints[.leftAnkle], let right = final.joints[.rightAnkle] else { return unavailable(phase, "The feet and body center were not visible at landing.") }
            let margin = abs(left.x - right.x) * 0.35
            let balanced = root.x >= min(left.x, right.x) - margin && root.x <= max(left.x, right.x) + margin
            return PhaseScore(phase: phase, score: balanced ? 84 : 62, confidence: confidence, note: balanced ? "The body center finishes over the visible landing base." : "The body center finishes outside the visible landing base.")
        }
    }

    private func framesFor(_ phase: ServePhaseKind, in frames: [PoseFrame], phases: [DetectedServePhase]) -> [PoseFrame] {
        guard let interval = phases.first(where: { $0.phase == phase }) else { return [] }
        return frames.filter { $0.timestamp >= interval.startTime && $0.timestamp <= interval.endTime }
    }

    private func kneeAngle(_ frame: PoseFrame) -> Double? {
        let triples: [(BodyJoint, BodyJoint, BodyJoint)] = [(.leftHip, .leftKnee, .leftAnkle), (.rightHip, .rightKnee, .rightAnkle)]
        return triples.compactMap { hip, knee, ankle in
            guard let a = frame.joints[hip], let b = frame.joints[knee], let c = frame.joints[ankle] else { return nil }
            return Geometry.angle(vertex: b.point, first: a.point, second: c.point)
        }.min()
    }

    private func elbowAngle(_ frame: PoseFrame) -> Double? {
        let triples: [(BodyJoint, BodyJoint, BodyJoint)] = [(.leftShoulder, .leftElbow, .leftWrist), (.rightShoulder, .rightElbow, .rightWrist)]
        return triples.compactMap { shoulder, elbow, wrist in
            guard let a = frame.joints[shoulder], let b = frame.joints[elbow], let c = frame.joints[wrist] else { return nil }
            return Geometry.angle(vertex: b.point, first: a.point, second: c.point)
        }.max()
    }

    private func shoulderTilt(_ frame: PoseFrame) -> Double? {
        guard let left = frame.joints[.leftShoulder], let right = frame.joints[.rightShoulder] else { return nil }
        return Geometry.lineAngle(left.point, right.point)
    }

    private func wristVerticalSpeeds(_ frames: [PoseFrame]) -> [Double] {
        zip(frames, frames.dropFirst()).compactMap { first, second in
            let firstPoint = [first.joints[.leftWrist], first.joints[.rightWrist]].compactMap { $0 }.max { $0.confidence < $1.confidence }
            let secondPoint = [second.joints[.leftWrist], second.joints[.rightWrist]].compactMap { $0 }.max { $0.confidence < $1.confidence }
            guard let firstPoint, let secondPoint else { return nil }
            return Geometry.velocity(from: firstPoint.point, at: first.timestamp, to: secondPoint.point, at: second.timestamp).map { Double($0.dy) }
        }
    }

    private func unavailable(_ phase: ServePhaseKind, _ reason: String) -> PhaseScore {
        PhaseScore(phase: phase, score: nil, confidence: .low, note: "Insufficient visibility — \(reason)")
    }

    private func level(_ value: Double) -> ConfidenceLevel { value >= 0.78 ? .high : (value >= 0.52 ? .medium : .low) }
}
