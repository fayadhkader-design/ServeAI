import Foundation

protocol ServeMetricsCalculating: Sendable {
    func calculate(
        frames: [PoseFrame],
        phases: [DetectedServePhase],
        cameraAngle: CameraAngle
    ) -> [TechnicalMetric]
}

struct ServeMetricsCalculator: ServeMetricsCalculating {
    func calculate(
        frames: [PoseFrame],
        phases: [DetectedServePhase],
        cameraAngle: CameraAngle
    ) -> [TechnicalMetric] {
        guard !frames.isEmpty else { return [] }
        var metrics: [TechnicalMetric] = []

        let loadingFrames = framesFor(.loading, in: frames, phases: phases)
        let kneeSamples = loadingFrames.compactMap(kneeSample)
            .filter { $0.angle >= 65 && $0.angle <= 175 }
        if kneeSamples.count >= 3,
           let angle = Geometry.percentile(kneeSamples.map(\.angle), 0.20) {
            let flexion = 180 - angle
            let averageConfidence = kneeSamples.map(\.confidence).reduce(0, +)
                / Double(kneeSamples.count)
            metrics.append(TechnicalMetric(
                title: "Robust knee flexion",
                value: "\(Int(flexion.rounded()))°",
                context: "Anatomical flexion estimate from the clearer leg across the loading sequence; isolated extreme frames are excluded.",
                confidence: level(averageConfidence),
                relatedPhase: .loading
            ))
        }

        if let highest = frames.max(by: { wristHeight(in: $0) < wristHeight(in: $1) }) {
            let height = wristHeight(in: highest)
            metrics.append(TechnicalMetric(title: "Peak wrist height", value: String(format: "%.2f body units", height), context: "Normalized vertical position; this is not racket-head height.", confidence: confidence(for: highest), relatedPhase: .contactPosition))
        }

        if let first = frames.first, let last = frames.last,
           let firstCenter = bodyCenter(in: first), let lastCenter = bodyCenter(in: last) {
            let displacement = lastCenter.x - firstCenter.x
            metrics.append(TechnicalMetric(title: "Center movement", value: String(format: "%+.2f frame widths", displacement), context: "Approximate horizontal travel from setup through recovery.", confidence: minimumConfidence(confidence(for: first), confidence(for: last)), relatedPhase: .landingFollowThrough))
        }

        if cameraAngle == .rear {
            let trophyFrames = framesFor(.trophyPosition, in: frames, phases: phases)
            let tiltSamples = trophyFrames.compactMap(shoulderTilt)
            if tiltSamples.count >= 3,
               let tilt = Geometry.percentile(tiltSamples.map(\.angle), 0.80),
               tilt < 82 {
                let averageConfidence = tiltSamples.map(\.confidence).reduce(0, +)
                    / Double(tiltSamples.count)
                metrics.append(TechnicalMetric(
                    title: "Rear-view shoulder-line tilt",
                    value: "\(Int(tilt.rounded()))°",
                    context: "Image-plane line tilt only; this is not a 3D shoulder or trunk angle.",
                    confidence: level(averageConfidence),
                    relatedPhase: .trophyPosition
                ))
            }
        }

        return metrics
    }

    private func kneeSample(in frame: PoseFrame) -> (angle: Double, confidence: Double)? {
        let triples: [(BodyJoint, BodyJoint, BodyJoint)] = [(.leftHip, .leftKnee, .leftAnkle), (.rightHip, .rightKnee, .rightAnkle)]
        return triples.compactMap { hip, knee, ankle -> (Double, Double)? in
            guard let a = frame.joints[hip], let b = frame.joints[knee], let c = frame.joints[ankle] else { return nil }
            let confidence = min(a.confidence, min(b.confidence, c.confidence))
            guard confidence >= 0.35,
                  let angle = Geometry.angle(vertex: b.point, first: a.point, second: c.point) else {
                return nil
            }
            return (angle, confidence)
        }.max(by: { $0.1 < $1.1 }).map { ($0.0, $0.1) }
    }

    private func wristHeight(in frame: PoseFrame) -> Double {
        max(frame.joints[.leftWrist]?.y ?? 0, frame.joints[.rightWrist]?.y ?? 0)
    }

    private func bodyCenter(in frame: PoseFrame) -> PosePoint? {
        if let root = frame.joints[.root] { return root }
        guard let left = frame.joints[.leftHip], let right = frame.joints[.rightHip] else { return nil }
        return PosePoint(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2, confidence: min(left.confidence, right.confidence))
    }

    private func shoulderTilt(in frame: PoseFrame) -> (angle: Double, confidence: Double)? {
        guard let left = frame.joints[.leftShoulder],
              let right = frame.joints[.rightShoulder],
              Geometry.distance(left.point, right.point) >= 0.035 else {
            return nil
        }
        let confidence = min(left.confidence, right.confidence)
        guard confidence >= 0.35 else { return nil }
        return (Geometry.acuteLineTilt(left.point, right.point), confidence)
    }

    private func framesFor(
        _ phase: ServePhaseKind,
        in frames: [PoseFrame],
        phases: [DetectedServePhase]
    ) -> [PoseFrame] {
        guard let interval = phases.first(where: { $0.phase == phase }) else { return [] }
        return frames.filter { $0.timestamp >= interval.startTime && $0.timestamp <= interval.endTime }
    }

    private func confidence(for frame: PoseFrame) -> ConfidenceLevel {
        level(frame.bodyConfidence)
    }

    private func level(_ value: Double) -> ConfidenceLevel {
        value >= 0.78 ? .high : (value >= 0.52 ? .medium : .low)
    }

    private func minimumConfidence(_ lhs: ConfidenceLevel, _ rhs: ConfidenceLevel) -> ConfidenceLevel {
        let rank: [ConfidenceLevel: Int] = [.low: 0, .medium: 1, .high: 2]
        return (rank[lhs] ?? 0) <= (rank[rhs] ?? 0) ? lhs : rhs
    }
}
