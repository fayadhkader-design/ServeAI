import Foundation

struct HeuristicPhaseScorer: Sendable {
    private enum ArmSide {
        case left
        case right
    }

    // These rules are deliberately conservative: a single 2D observation can support
    // a visible criterion, but it cannot establish an exact 3D biomechanical ideal.
    func score(
        frames: [PoseFrame],
        phases: [DetectedServePhase],
        cameraAngle: CameraAngle = .rear
    ) -> [PhaseScore] {
        let hittingArm = hittingArm(in: frames, phases: phases)
        return ServePhaseKind.allCases.map { phase in
            let phaseFrames = evidenceFrames(for: phase, in: frames, phases: phases)
            guard !phaseFrames.isEmpty else {
                return PhaseScore(phase: phase, score: nil, confidence: .low, note: "Insufficient visibility — this phase could not be isolated.")
            }
            return score(
                phase,
                frames: phaseFrames,
                hittingArm: hittingArm,
                cameraAngle: cameraAngle
            )
        }
    }

    private func score(
        _ phase: ServePhaseKind,
        frames: [PoseFrame],
        hittingArm: ArmSide?,
        cameraAngle: CameraAngle
    ) -> PhaseScore {
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
            guard let hittingArm else {
                return unavailable(phase, "The hitting arm could not be identified, so the toss arm is ambiguous.")
            }
            let tossWrist = wristJoint(for: opposite(of: hittingArm))
            let peak = frames.compactMap { $0.joints[tossWrist] }
                .filter { $0.confidence >= 0.35 }
                .max { $0.y < $1.y }
            guard let peak else { return unavailable(phase, "The tossing wrist was not visible.") }
            let score = Int(max(50, min(90, 55 + peak.y * 40)))
            return PhaseScore(phase: phase, score: score, confidence: confidence, note: peak.y > 0.80 ? "The visible wrist reaches full overhead extension." : "The visible wrist peaks below the expected overhead range.")
        case .loading:
            let kneeSamples = frames.compactMap(clearerKneeSample)
                // Values outside this range are commonly caused by crossed limbs,
                // occlusion, or a brief 2D pose-identity swap.
                .filter { $0.angle >= 65 && $0.angle <= 175 }
            guard kneeSamples.count >= 3,
                  let robustInteriorAngle = Geometry.percentile(kneeSamples.map(\.angle), 0.20) else {
                return unavailable(phase, "A stable knee-angle sequence was not visible; an isolated extreme frame was ignored.")
            }
            let flexion = 180 - robustInteriorAngle
            let score: Int
            if flexion >= 45 && flexion <= 85 {
                score = 90
            } else if flexion < 45 {
                score = Int(max(68, 90 - (45 - flexion) * 0.8))
            } else {
                score = Int(max(72, 90 - (flexion - 85) * 0.8))
            }
            return PhaseScore(
                phase: phase,
                score: score,
                confidence: evidenceConfidence(
                    samples: kneeSamples.map(\.confidence),
                    expectedCount: frames.count
                ),
                note: "Robust visible knee flexion is approximately \(Int(flexion.rounded()))°; isolated extreme frames were excluded."
            )
        case .trophyPosition:
            guard cameraAngle == .rear else {
                return unavailable(phase, "Shoulder-line tilt is projection-sensitive from the side view and is not graded as a 3D trophy-position measurement.")
            }
            let tiltSamples = frames.compactMap(shoulderTiltSample)
            guard tiltSamples.count >= 3,
                  let robustTilt = Geometry.percentile(tiltSamples.map(\.angle), 0.80),
                  robustTilt < 82 else {
                return unavailable(phase, "A stable rear-view shoulder line was not visible.")
            }
            let score: Int
            if robustTilt >= 15 {
                score = 88
            } else {
                score = Int(max(65, 76 + robustTilt * 0.8))
            }
            return PhaseScore(
                phase: phase,
                score: score,
                confidence: evidenceConfidence(
                    samples: tiltSamples.map(\.confidence),
                    expectedCount: frames.count
                ),
                note: "Rear-view shoulder-line tilt is approximately \(Int(robustTilt.rounded()))° in the image plane; it is not a 3D joint angle."
            )
        case .legDrive:
            guard let first = frames.first?.joints[.root], let last = frames.last?.joints[.root] else { return unavailable(phase, "The body center was not tracked through the drive.") }
            let rise = last.y - first.y
            let score = Int(max(45, min(92, 65 + rise * 180)))
            return PhaseScore(phase: phase, score: score, confidence: confidence, note: rise > 0.05 ? "The body center rises during the drive." : "Limited upward body-center movement was visible.")
        case .racketDrop:
            guard let hittingArm else {
                return unavailable(phase, "The hitting arm could not be identified near contact.")
            }
            return racketDropProxy(frames: frames, arm: hittingArm)
        case .upwardAcceleration:
            guard let hittingArm else {
                return unavailable(phase, "The hitting arm could not be identified near contact.")
            }
            let speeds = wristVerticalSpeeds(frames, arm: hittingArm)
            guard let peak = speeds.max() else { return unavailable(phase, "The hitting wrist was not tracked continuously.") }
            let score = Int(max(50, min(90, 58 + peak * 12)))
            return PhaseScore(phase: phase, score: score, confidence: confidence, note: "The visible wrist gains upward speed before its highest point.")
        case .contactPosition:
            guard let hittingArm else {
                return unavailable(phase, "The hitting arm could not be identified near contact.")
            }
            let extensions = frames.compactMap { elbowAngle($0, arm: hittingArm) }
            guard let maximum = extensions.max() else { return unavailable(phase, "Shoulder, elbow, and wrist were not visible together.") }
            let score = Int(max(50, min(94, 55 + (maximum - 120) * 0.8)))
            return PhaseScore(phase: phase, score: score, confidence: confidence, note: "Maximum visible hitting-arm extension is approximately \(Int(maximum.rounded()))°.")
        case .pronation:
            guard let hittingArm else {
                return unavailable(phase, "The hitting arm could not be identified near contact.")
            }
            return pronationProxy(frames: frames, arm: hittingArm)
        case .landingFollowThrough:
            guard let final = frames.last, let root = final.joints[.root], let left = final.joints[.leftAnkle], let right = final.joints[.rightAnkle] else { return unavailable(phase, "The feet and body center were not visible at landing.") }
            let margin = abs(left.x - right.x) * 0.35
            let balanced = root.x >= min(left.x, right.x) - margin && root.x <= max(left.x, right.x) + margin
            return PhaseScore(phase: phase, score: balanced ? 84 : 62, confidence: confidence, note: balanced ? "The body center finishes over the visible landing base." : "The body center finishes outside the visible landing base.")
        }
    }

    private func evidenceFrames(
        for phase: ServePhaseKind,
        in frames: [PoseFrame],
        phases: [DetectedServePhase]
    ) -> [PoseFrame] {
        switch phase {
        case .racketDrop:
            return framesBetween(
                in: frames,
                from: phases.first(where: { $0.phase == .legDrive })?.startTime,
                through: phases.first(where: { $0.phase == .upwardAcceleration })?.endTime
            ) ?? framesFor(phase, in: frames, phases: phases)
        case .pronation:
            return framesBetween(
                in: frames,
                from: phases.first(where: { $0.phase == .contactPosition })?.startTime,
                through: phases.first(where: { $0.phase == .pronation })?.endTime
            ) ?? framesFor(phase, in: frames, phases: phases)
        default:
            return framesFor(phase, in: frames, phases: phases)
        }
    }

    private func framesBetween(
        in frames: [PoseFrame],
        from startTime: TimeInterval?,
        through endTime: TimeInterval?
    ) -> [PoseFrame]? {
        guard let startTime, let endTime, endTime >= startTime else { return nil }
        let selected = frames.filter {
            $0.timestamp >= startTime && $0.timestamp <= endTime
        }
        return selected.isEmpty ? nil : selected
    }

    private func framesFor(_ phase: ServePhaseKind, in frames: [PoseFrame], phases: [DetectedServePhase]) -> [PoseFrame] {
        guard let interval = phases.first(where: { $0.phase == phase }) else { return [] }
        return frames.filter { $0.timestamp >= interval.startTime && $0.timestamp <= interval.endTime }
    }

    private func hittingArm(
        in frames: [PoseFrame],
        phases: [DetectedServePhase]
    ) -> ArmSide? {
        let contactFrames = framesFor(.contactPosition, in: frames, phases: phases)
        let candidates = contactFrames.isEmpty
            ? Array(frames.suffix(max(1, frames.count / 3)))
            : contactFrames
        let leftScore = armSelectionScore(in: candidates, arm: .left)
        let rightScore = armSelectionScore(in: candidates, arm: .right)
        switch (leftScore, rightScore) {
        case let (left?, right?):
            return left >= right ? .left : .right
        case (.some, .none):
            return .left
        case (.none, .some):
            return .right
        case (.none, .none):
            return nil
        }
    }

    private func armSelectionScore(
        in frames: [PoseFrame],
        arm: ArmSide
    ) -> Double? {
        frames.compactMap { frame -> Double? in
            guard let points = armPoints(in: frame, arm: arm),
                  let extensionAngle = Geometry.angle(
                    vertex: points.elbow.point,
                    first: points.shoulder.point,
                    second: points.wrist.point
                  ) else {
                return nil
            }
            let confidence = (
                points.shoulder.confidence
                    + points.elbow.confidence
                    + points.wrist.confidence
            ) / 3
            return extensionAngle / 180 * 0.65
                + points.wrist.y * 0.25
                + confidence * 0.10
        }.max()
    }

    private func racketDropProxy(
        frames: [PoseFrame],
        arm: ArmSide
    ) -> PhaseScore {
        let samples = frames.compactMap { frame -> (depth: Double, confidence: Double)? in
            guard let points = armPoints(in: frame, arm: arm),
                  let scale = torsoScale(in: frame),
                  scale > 0.04 else {
                return nil
            }
            let depth = (points.shoulder.y - points.wrist.y) / scale
            let confidence = (
                points.shoulder.confidence
                    + points.elbow.confidence
                    + points.wrist.confidence
            ) / 3
            return (depth, confidence)
        }
        guard let deepest = samples.max(by: { $0.depth < $1.depth }) else {
            return unavailable(.racketDrop, "The hitting shoulder, elbow, and wrist were not visible together.")
        }
        let boundedDepth = max(0, min(1, deepest.depth))
        let score = Int((55 + boundedDepth * 35).rounded())
        let averageConfidence = samples.map(\.confidence).reduce(0, +)
            / Double(samples.count)
        return PhaseScore(
            phase: .racketDrop,
            score: score,
            confidence: proxyConfidence(
                jointConfidence: averageConfidence,
                coverage: Double(samples.count) / Double(max(frames.count, 1))
            ),
            note: String(
                format: "Wrist-drop proxy: the hitting wrist reached %.2f torso lengths below the shoulder. This does not measure racket-head depth.",
                max(0, deepest.depth)
            )
        )
    }

    private func pronationProxy(
        frames: [PoseFrame],
        arm: ArmSide
    ) -> PhaseScore {
        let samples = frames.compactMap { frame -> (angle: Double, confidence: Double)? in
            guard let points = armPoints(in: frame, arm: arm) else { return nil }
            let confidence = (points.elbow.confidence + points.wrist.confidence) / 2
            return (
                Geometry.lineAngle(points.elbow.point, points.wrist.point),
                confidence
            )
        }
        guard samples.count >= 2 else {
            return unavailable(.pronation, "The hitting elbow and wrist were not tracked through contact.")
        }
        let angles = unwrapped(samples.map(\.angle))
        guard let minimum = angles.min(), let maximum = angles.max() else {
            return unavailable(.pronation, "Post-contact forearm movement could not be estimated.")
        }
        let sweep = abs(maximum - minimum)
        let score = Int((55 + min(35, sweep * 0.5)).rounded())
        let averageConfidence = samples.map(\.confidence).reduce(0, +)
            / Double(samples.count)
        return PhaseScore(
            phase: .pronation,
            score: score,
            confidence: proxyConfidence(
                jointConfidence: averageConfidence,
                coverage: Double(samples.count) / Double(max(frames.count, 1))
            ),
            note: String(
                format: "Forearm-path proxy: the elbow-to-wrist line rotated about %.0f° in the image plane after contact. Axial pronation is not measured directly.",
                sweep
            )
        )
    }

    private func armPoints(
        in frame: PoseFrame,
        arm: ArmSide
    ) -> (shoulder: PosePoint, elbow: PosePoint, wrist: PosePoint)? {
        let joints: (BodyJoint, BodyJoint, BodyJoint) = switch arm {
        case .left:
            (.leftShoulder, .leftElbow, .leftWrist)
        case .right:
            (.rightShoulder, .rightElbow, .rightWrist)
        }
        guard let shoulder = frame.joints[joints.0],
              let elbow = frame.joints[joints.1],
              let wrist = frame.joints[joints.2] else {
            return nil
        }
        return (shoulder, elbow, wrist)
    }

    private func opposite(of arm: ArmSide) -> ArmSide {
        arm == .left ? .right : .left
    }

    private func wristJoint(for arm: ArmSide) -> BodyJoint {
        arm == .left ? .leftWrist : .rightWrist
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

    private func unwrapped(_ angles: [Double]) -> [Double] {
        guard let first = angles.first else { return [] }
        var result = [first]
        var previousRaw = first
        for angle in angles.dropFirst() {
            var delta = angle - previousRaw
            while delta > 180 { delta -= 360 }
            while delta < -180 { delta += 360 }
            result.append((result.last ?? first) + delta)
            previousRaw = angle
        }
        return result
    }

    private func proxyConfidence(
        jointConfidence: Double,
        coverage: Double
    ) -> ConfidenceLevel {
        jointConfidence >= 0.65 && coverage >= 0.55 ? .medium : .low
    }

    private func clearerKneeSample(_ frame: PoseFrame) -> (angle: Double, confidence: Double)? {
        let triples: [(BodyJoint, BodyJoint, BodyJoint)] = [(.leftHip, .leftKnee, .leftAnkle), (.rightHip, .rightKnee, .rightAnkle)]
        return triples.compactMap { hip, knee, ankle -> (angle: Double, confidence: Double)? in
            guard let a = frame.joints[hip], let b = frame.joints[knee], let c = frame.joints[ankle] else { return nil }
            let confidence = min(a.confidence, b.confidence, c.confidence)
            guard confidence >= 0.35,
                  let angle = Geometry.angle(vertex: b.point, first: a.point, second: c.point) else {
                return nil
            }
            return (angle, confidence)
        }.max(by: { $0.confidence < $1.confidence })
    }

    private func elbowAngle(_ frame: PoseFrame, arm: ArmSide) -> Double? {
        guard let points = armPoints(in: frame, arm: arm),
              min(points.shoulder.confidence, points.elbow.confidence, points.wrist.confidence) >= 0.35 else {
            return nil
        }
        return Geometry.angle(
            vertex: points.elbow.point,
            first: points.shoulder.point,
            second: points.wrist.point
        )
    }

    private func shoulderTiltSample(_ frame: PoseFrame) -> (angle: Double, confidence: Double)? {
        guard let left = frame.joints[.leftShoulder],
              let right = frame.joints[.rightShoulder],
              min(left.confidence, right.confidence) >= 0.35,
              Geometry.distance(left.point, right.point) >= 0.035 else {
            return nil
        }
        return (
            Geometry.acuteLineTilt(left.point, right.point),
            min(left.confidence, right.confidence)
        )
    }

    private func wristVerticalSpeeds(_ frames: [PoseFrame], arm: ArmSide) -> [Double] {
        let joint = wristJoint(for: arm)
        return zip(frames, frames.dropFirst()).compactMap { first, second -> Double? in
            guard let firstPoint = first.joints[joint],
                  let secondPoint = second.joints[joint],
                  min(firstPoint.confidence, secondPoint.confidence) >= 0.35 else {
                return nil
            }
            guard let velocity = Geometry.velocity(
                from: firstPoint.point,
                at: first.timestamp,
                to: secondPoint.point,
                at: second.timestamp
            ) else {
                return nil
            }
            return Double(velocity.dy)
        }
    }

    private func unavailable(_ phase: ServePhaseKind, _ reason: String) -> PhaseScore {
        PhaseScore(phase: phase, score: nil, confidence: .low, note: "Insufficient visibility — \(reason)")
    }

    private func evidenceConfidence(
        samples: [Double],
        expectedCount: Int
    ) -> ConfidenceLevel {
        guard !samples.isEmpty else { return .low }
        let jointConfidence = samples.reduce(0, +) / Double(samples.count)
        let coverage = Double(samples.count) / Double(max(expectedCount, 1))
        let combined = jointConfidence * 0.70 + coverage * 0.30
        return level(combined)
    }

    private func level(_ value: Double) -> ConfidenceLevel { value >= 0.78 ? .high : (value >= 0.52 ? .medium : .low) }
}
