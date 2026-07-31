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
        guard quality >= 0.35 else {
            return PhaseScore(phase: phase, score: nil, confidence: .low, note: "Insufficient visibility — too few required joints were tracked.")
        }

        switch phase {
        case .startingStance:
            return startingBalanceProxy(frames: frames)
        case .ballToss:
            guard let hittingArm else {
                return unavailable(phase, "The hitting arm could not be identified, so the toss arm is ambiguous.")
            }
            return tossArmProxy(frames: frames, arm: opposite(of: hittingArm))
        case .loading:
            let kneeSamples = frames.compactMap(clearerKneeSample)
                // Values outside this range are commonly caused by crossed limbs,
                // occlusion, or a brief 2D pose-identity swap.
                .filter { $0.angle >= 65 && $0.angle <= 175 }
            guard kneeSamples.count >= 3,
                  let robustInteriorAngle = Geometry.robustPercentile(kneeSamples.map(\.angle), 0.20) else {
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
                  let robustTilt = Geometry.robustPercentile(tiltSamples.map(\.angle), 0.80),
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
            return legDriveProxy(frames: frames)
        case .racketDrop:
            guard let hittingArm else {
                return unavailable(phase, "The hitting arm could not be identified near contact.")
            }
            return racketDropProxy(frames: frames, arm: hittingArm)
        case .upwardAcceleration:
            guard let hittingArm else {
                return unavailable(phase, "The hitting arm could not be identified near contact.")
            }
            return upwardArmPathProxy(frames: frames, arm: hittingArm)
        case .contactPosition:
            guard let hittingArm else {
                return unavailable(phase, "The hitting arm could not be identified near contact.")
            }
            return contactExtensionProxy(frames: frames, arm: hittingArm)
        case .pronation:
            guard let hittingArm else {
                return unavailable(phase, "The hitting arm could not be identified near contact.")
            }
            return pronationProxy(frames: frames, arm: hittingArm)
        case .landingFollowThrough:
            return landingBalanceProxy(frames: frames, cameraAngle: cameraAngle)
        }
    }

    private func evidenceFrames(
        for phase: ServePhaseKind,
        in frames: [PoseFrame],
        phases: [DetectedServePhase]
    ) -> [PoseFrame] {
        switch phase {
        case .legDrive:
            return framesBetween(
                in: frames,
                from: phases.first(where: { $0.phase == .loading })?.startTime,
                through: phases.first(where: { $0.phase == .upwardAcceleration })?.endTime
            ) ?? framesFor(phase, in: frames, phases: phases)
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
        let dropFrames = framesBetween(
            in: frames,
            from: phases.first(where: { $0.phase == .racketDrop })?.startTime,
            through: phases.first(where: { $0.phase == .upwardAcceleration })?.startTime
        ) ?? []
        let leftScore = armSelectionScore(
            contactFrames: candidates,
            dropFrames: dropFrames,
            arm: .left
        )
        let rightScore = armSelectionScore(
            contactFrames: candidates,
            dropFrames: dropFrames,
            arm: .right
        )
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
        contactFrames: [PoseFrame],
        dropFrames: [PoseFrame],
        arm: ArmSide
    ) -> Double? {
        let contactSamples = contactFrames.compactMap { frame -> (extensionAngle: Double, height: Double, confidence: Double)? in
            guard let points = armPoints(in: frame, arm: arm),
                  let scale = torsoScale(in: frame),
                  scale > 0.04,
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
            return (
                extensionAngle,
                (points.wrist.y - points.shoulder.y) / scale,
                confidence
            )
        }
        guard let extensionAngle = Geometry.robustPercentile(contactSamples.map(\.extensionAngle), 0.80),
              let contactHeight = Geometry.robustPercentile(contactSamples.map(\.height), 0.80) else {
            return nil
        }
        let dropHeights = dropFrames.compactMap { frame -> Double? in
            guard let points = armPoints(in: frame, arm: arm),
                  let scale = torsoScale(in: frame),
                  scale > 0.04 else {
                return nil
            }
            return (points.wrist.y - points.shoulder.y) / scale
        }
        let dropHeight = Geometry.robustPercentile(dropHeights, 0.20) ?? contactHeight
        let upwardRange = max(0, contactHeight - dropHeight)
        let confidence = contactSamples.map(\.confidence).reduce(0, +)
            / Double(contactSamples.count)
        return extensionAngle / 180 * 0.45
            + max(0, min(1.5, contactHeight)) / 1.5 * 0.20
            + max(0, min(1.5, upwardRange)) / 1.5 * 0.30
            + confidence * 0.05
    }

    private func tossArmProxy(
        frames: [PoseFrame],
        arm: ArmSide
    ) -> PhaseScore {
        let samples = frames.compactMap { frame -> (height: Double, extensionAngle: Double, confidence: Double)? in
            guard let points = armPoints(in: frame, arm: arm),
                  let scale = torsoScale(in: frame),
                  scale > 0.04,
                  let extensionAngle = Geometry.angle(
                    vertex: points.elbow.point,
                    first: points.shoulder.point,
                    second: points.wrist.point
                  ) else {
                return nil
            }
            let confidence = min(
                points.shoulder.confidence,
                min(points.elbow.confidence, points.wrist.confidence)
            )
            guard confidence >= 0.35 else { return nil }
            return (
                (points.wrist.y - points.shoulder.y) / scale,
                extensionAngle,
                confidence
            )
        }
        guard samples.count >= 3,
              let height = Geometry.robustPercentile(samples.map(\.height), 0.80),
              let extensionAngle = Geometry.robustPercentile(samples.map(\.extensionAngle), 0.80) else {
            return unavailable(.ballToss, "The toss shoulder, elbow, and wrist were not tracked together across multiple frames.")
        }
        let heightScore = boundedScore(60 + (height - 0.25) * 42, lower: 58, upper: 92)
        let extensionScore = boundedScore(60 + (extensionAngle - 110) * 0.58, lower: 58, upper: 94)
        let score = Int((Double(heightScore) * 0.45 + Double(extensionScore) * 0.55).rounded())
        let averageConfidence = samples.map(\.confidence).reduce(0, +) / Double(samples.count)
        return PhaseScore(
            phase: .ballToss,
            score: score,
            confidence: proxyConfidence(
                jointConfidence: averageConfidence,
                coverage: Double(samples.count) / Double(max(frames.count, 1))
            ),
            note: String(
                format: "Toss-arm proxy: the wrist rose %.2f torso lengths above its shoulder with about %.0f° elbow extension. Ball placement is not measured.",
                height,
                extensionAngle
            )
        )
    }

    private func startingBalanceProxy(frames: [PoseFrame]) -> PhaseScore {
        let samples = frames.compactMap { frame -> (offset: Double, confidence: Double)? in
            guard let root = frame.joints[.root],
                  let left = frame.joints[.leftAnkle],
                  let right = frame.joints[.rightAnkle],
                  let scale = torsoScale(in: frame),
                  scale > 0.04 else {
                return nil
            }
            let confidence = min(root.confidence, min(left.confidence, right.confidence))
            guard confidence >= 0.35 else { return nil }
            let lower = min(left.x, right.x)
            let upper = max(left.x, right.x)
            let offset = root.x < lower
                ? (lower - root.x) / scale
                : (root.x > upper ? (root.x - upper) / scale : 0)
            return (offset, confidence)
        }
        guard let offset = Geometry.robustPercentile(samples.map(\.offset), 0.70) else {
            return unavailable(.startingStance, "Feet and body center were not visible together at setup.")
        }
        let score = boundedScore(84 - max(0, offset - 0.10) * 40, lower: 60, upper: 84)
        return PhaseScore(
            phase: .startingStance,
            score: score,
            confidence: evidenceConfidence(
                samples: samples.map(\.confidence),
                expectedCount: frames.count
            ),
            note: String(
                format: "Setup-balance proxy: body center was %.2f torso lengths beyond the visible base of support. Stance style is not graded.",
                offset
            )
        )
    }

    private func legDriveProxy(frames: [PoseFrame]) -> PhaseScore {
        let left = kneeExtensionEvidence(frames: frames, side: .left)
        let right = kneeExtensionEvidence(frames: frames, side: .right)
        let kneeEvidence = [left, right]
            .compactMap { $0 }
            .max { $0.reliability < $1.reliability }
        let rootEvidence = rootRiseEvidence(frames: frames)
        guard kneeEvidence != nil || rootEvidence != nil else {
            return unavailable(.legDrive, "A stable knee-extension or body-center-rise sequence was not visible.")
        }

        var components: [Double] = []
        if let range = kneeEvidence?.extensionRange {
            components.append(Double(boundedScore(62 + range * 1.1, lower: 60, upper: 92)))
        }
        if let rise = rootEvidence?.rise {
            components.append(Double(boundedScore(62 + rise * 100, lower: 60, upper: 92)))
        }
        let score = Int((components.reduce(0, +) / Double(components.count)).rounded())
        let confidenceSamples = (kneeEvidence?.confidences ?? []) + (rootEvidence?.confidences ?? [])
        let confidence = evidenceConfidence(
            samples: confidenceSamples,
            expectedCount: frames.count * (kneeEvidence != nil && rootEvidence != nil ? 2 : 1)
        )
        let rangeDescription = kneeEvidence.map { String(format: "%.0f°", $0.extensionRange) } ?? "unavailable"
        let riseDescription = rootEvidence.map { String(format: "%.2f torso lengths", $0.rise) } ?? "unavailable"
        return PhaseScore(
            phase: .legDrive,
            score: score,
            confidence: confidence,
            note: "Leg-drive proxy: visible knee extension range was \(rangeDescription) and body-center rise was \(riseDescription)."
        )
    }

    private func upwardArmPathProxy(
        frames: [PoseFrame],
        arm: ArmSide
    ) -> PhaseScore {
        let samples = frames.compactMap { frame -> (height: Double, confidence: Double)? in
            guard let points = armPoints(in: frame, arm: arm),
                  let scale = torsoScale(in: frame),
                  scale > 0.04 else {
                return nil
            }
            let confidence = min(points.shoulder.confidence, points.wrist.confidence)
            guard confidence >= 0.35 else { return nil }
            return ((points.wrist.y - points.shoulder.y) / scale, confidence)
        }
        guard samples.count >= 3 else {
            return unavailable(.upwardAcceleration, "The hitting wrist was not tracked continuously relative to the shoulder.")
        }
        let split = max(1, samples.count / 3)
        let early = Array(samples.prefix(split))
        let late = Array(samples.suffix(split))
        guard let earlyHeight = Geometry.robustPercentile(early.map(\.height), 0.20),
              let lateHeight = Geometry.robustPercentile(late.map(\.height), 0.80) else {
            return unavailable(.upwardAcceleration, "The upward hitting-arm path could not be estimated.")
        }
        let rise = lateHeight - earlyHeight
        let score = boundedScore(62 + rise * 30, lower: 55, upper: 92)
        let averageConfidence = samples.map(\.confidence).reduce(0, +) / Double(samples.count)
        return PhaseScore(
            phase: .upwardAcceleration,
            score: score,
            confidence: proxyConfidence(
                jointConfidence: averageConfidence,
                coverage: Double(samples.count) / Double(max(frames.count, 1))
            ),
            note: String(
                format: "Upward arm-path proxy: the hitting wrist rose %.2f torso lengths through the acceleration window. Racket-head acceleration is not measured.",
                rise
            )
        )
    }

    private func contactExtensionProxy(
        frames: [PoseFrame],
        arm: ArmSide
    ) -> PhaseScore {
        let samples = frames.compactMap { frame -> (extensionAngle: Double, height: Double, confidence: Double)? in
            guard let points = armPoints(in: frame, arm: arm),
                  let scale = torsoScale(in: frame),
                  scale > 0.04,
                  let extensionAngle = elbowAngle(frame, arm: arm) else {
                return nil
            }
            let confidence = min(
                points.shoulder.confidence,
                min(points.elbow.confidence, points.wrist.confidence)
            )
            return (
                extensionAngle,
                (points.wrist.y - points.shoulder.y) / scale,
                confidence
            )
        }
        guard samples.count >= 2,
              let extensionAngle = Geometry.robustPercentile(samples.map(\.extensionAngle), 0.80),
              let height = Geometry.robustPercentile(samples.map(\.height), 0.80) else {
            return unavailable(.contactPosition, "Shoulder, elbow, and wrist were not visible together across likely contact frames.")
        }
        let extensionScore = boundedScore(55 + (extensionAngle - 110) * 0.65, lower: 52, upper: 94)
        let heightScore = boundedScore(60 + (height - 0.30) * 32, lower: 55, upper: 92)
        let score = Int((Double(extensionScore) * 0.70 + Double(heightScore) * 0.30).rounded())
        let averageConfidence = samples.map(\.confidence).reduce(0, +) / Double(samples.count)
        return PhaseScore(
            phase: .contactPosition,
            score: score,
            confidence: proxyConfidence(
                jointConfidence: averageConfidence,
                coverage: Double(samples.count) / Double(max(frames.count, 1))
            ),
            note: String(
                format: "Likely-contact proxy: hitting-arm extension was about %.0f° and the wrist was %.2f torso lengths above the shoulder. Ball-racket impact is not detected.",
                extensionAngle,
                height
            )
        )
    }

    private func landingBalanceProxy(
        frames: [PoseFrame],
        cameraAngle: CameraAngle
    ) -> PhaseScore {
        let samples = frames.compactMap { frame -> (offset: Double, confidence: Double)? in
            guard let root = frame.joints[.root],
                  let scale = torsoScale(in: frame),
                  scale > 0.04 else {
                return nil
            }
            let ankles = [frame.joints[.leftAnkle], frame.joints[.rightAnkle]]
                .compactMap { $0 }
                .filter { $0.confidence >= 0.35 }
            guard !ankles.isEmpty else { return nil }
            let offset: Double
            if cameraAngle == .rear, ankles.count == 2 {
                let lower = ankles.map(\.x).min() ?? root.x
                let upper = ankles.map(\.x).max() ?? root.x
                offset = root.x < lower
                    ? (lower - root.x) / scale
                    : (root.x > upper ? (root.x - upper) / scale : 0)
            } else {
                offset = ankles.map { abs(root.x - $0.x) / scale }.min() ?? 0
            }
            let confidence = min(root.confidence, ankles.map(\.confidence).max() ?? 0)
            return (offset, confidence)
        }
        guard samples.count >= 2,
              let offset = Geometry.robustPercentile(samples.map(\.offset), 0.70) else {
            return unavailable(.landingFollowThrough, "The landing foot and body center were not tracked together across multiple frames.")
        }
        let allowance = cameraAngle == .rear ? 0.15 : 0.50
        let score = boundedScore(86 - max(0, offset - allowance) * 38, lower: 58, upper: 86)
        let viewDescription = cameraAngle == .rear ? "lateral support" : "nearest landing foot"
        return PhaseScore(
            phase: .landingFollowThrough,
            score: score,
            confidence: evidenceConfidence(
                samples: samples.map(\.confidence),
                expectedCount: frames.count
            ),
            note: String(
                format: "Landing-balance proxy: body center remained %.2f torso lengths beyond the visible %@ reference.",
                offset,
                viewDescription
            )
        )
    }

    private func kneeExtensionEvidence(
        frames: [PoseFrame],
        side: ArmSide
    ) -> (extensionRange: Double, reliability: Double, confidences: [Double])? {
        let samples = frames.compactMap { frame -> (angle: Double, confidence: Double)? in
            kneeSample(frame, side: side)
        }.filter { $0.angle >= 65 && $0.angle <= 175 }
        guard samples.count >= 4 else { return nil }
        let half = max(2, samples.count / 2)
        guard let loaded = Geometry.robustPercentile(Array(samples.prefix(half)).map(\.angle), 0.20),
              let extended = Geometry.robustPercentile(Array(samples.suffix(half)).map(\.angle), 0.80) else {
            return nil
        }
        let confidences = samples.map(\.confidence)
        let averageConfidence = confidences.reduce(0, +) / Double(confidences.count)
        let coverage = Double(samples.count) / Double(max(frames.count, 1))
        return (max(0, extended - loaded), averageConfidence * coverage, confidences)
    }

    private func rootRiseEvidence(
        frames: [PoseFrame]
    ) -> (rise: Double, confidences: [Double])? {
        let samples = frames.compactMap { frame -> (height: Double, scale: Double, confidence: Double)? in
            guard let root = frame.joints[.root],
                  let scale = torsoScale(in: frame),
                  scale > 0.04,
                  root.confidence >= 0.35 else {
                return nil
            }
            return (root.y, scale, root.confidence)
        }
        guard samples.count >= 4 else { return nil }
        let third = max(2, samples.count / 3)
        guard let early = Geometry.robustPercentile(Array(samples.prefix(third)).map(\.height), 0.30),
              let late = Geometry.robustPercentile(Array(samples.suffix(third)).map(\.height), 0.70),
              let scale = Geometry.percentile(samples.map(\.scale), 0.50),
              scale > 0.04 else {
            return nil
        }
        return (max(0, (late - early) / scale), samples.map(\.confidence))
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
        guard samples.count >= 3,
              let robustDepth = Geometry.robustPercentile(samples.map(\.depth), 0.80) else {
            return unavailable(.racketDrop, "The hitting shoulder, elbow, and wrist were not visible together.")
        }
        let boundedDepth = max(0, min(1, robustDepth))
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
                max(0, robustDepth)
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
        guard samples.count >= 3 else {
            return unavailable(.pronation, "The hitting elbow and wrist were not tracked through contact.")
        }
        let angles = unwrapped(samples.map(\.angle))
        guard let minimum = Geometry.robustPercentile(angles, 0.10),
              let maximum = Geometry.robustPercentile(angles, 0.90) else {
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
        [ArmSide.left, .right]
            .compactMap { kneeSample(frame, side: $0) }
            .max(by: { $0.confidence < $1.confidence })
    }

    private func kneeSample(
        _ frame: PoseFrame,
        side: ArmSide
    ) -> (angle: Double, confidence: Double)? {
        let joints: (BodyJoint, BodyJoint, BodyJoint) = switch side {
        case .left: (.leftHip, .leftKnee, .leftAnkle)
        case .right: (.rightHip, .rightKnee, .rightAnkle)
        }
        guard let hip = frame.joints[joints.0],
              let knee = frame.joints[joints.1],
              let ankle = frame.joints[joints.2] else {
            return nil
        }
        let confidence = min(hip.confidence, min(knee.confidence, ankle.confidence))
        guard confidence >= 0.35,
              let angle = Geometry.angle(
                vertex: knee.point,
                first: hip.point,
                second: ankle.point
              ) else {
            return nil
        }
        return (angle, confidence)
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

    private func boundedScore(
        _ value: Double,
        lower: Int,
        upper: Int
    ) -> Int {
        Int(max(Double(lower), min(Double(upper), value)).rounded())
    }

    private func level(_ value: Double) -> ConfidenceLevel { value >= 0.78 ? .high : (value >= 0.52 ? .medium : .low) }
}
