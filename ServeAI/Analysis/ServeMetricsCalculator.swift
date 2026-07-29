import Foundation

protocol ServeMetricsCalculating: Sendable {
    func calculate(frames: [PoseFrame], phases: [DetectedServePhase]) -> [TechnicalMetric]
}

struct ServeMetricsCalculator: ServeMetricsCalculating {
    func calculate(frames: [PoseFrame], phases: [DetectedServePhase]) -> [TechnicalMetric] {
        guard !frames.isEmpty else { return [] }
        var metrics: [TechnicalMetric] = []

        if let loaded = frames.min(by: { (kneeAngle(in: $0) ?? 180) < (kneeAngle(in: $1) ?? 180) }),
           let angle = kneeAngle(in: loaded) {
            metrics.append(TechnicalMetric(title: "Deepest knee flexion", value: "\(Int(angle.rounded()))°", context: "Estimated from the clearer leg; 180° is straight.", confidence: confidence(for: loaded), relatedPhase: .loading))
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

        if let trophy = frames.max(by: { abs(shoulderTilt(in: $0) ?? 0) < abs(shoulderTilt(in: $1) ?? 0) }), let tilt = shoulderTilt(in: trophy) {
            metrics.append(TechnicalMetric(title: "Peak shoulder tilt", value: "\(Int(abs(tilt).rounded()))°", context: "Estimated angle of the shoulder line relative to horizontal.", confidence: confidence(for: trophy), relatedPhase: .trophyPosition))
        }

        return metrics
    }

    private func kneeAngle(in frame: PoseFrame) -> Double? {
        let triples: [(BodyJoint, BodyJoint, BodyJoint)] = [(.leftHip, .leftKnee, .leftAnkle), (.rightHip, .rightKnee, .rightAnkle)]
        return triples.compactMap { hip, knee, ankle in
            guard let a = frame.joints[hip], let b = frame.joints[knee], let c = frame.joints[ankle] else { return nil }
            return Geometry.angle(vertex: b.point, first: a.point, second: c.point)
        }.min()
    }

    private func wristHeight(in frame: PoseFrame) -> Double {
        max(frame.joints[.leftWrist]?.y ?? 0, frame.joints[.rightWrist]?.y ?? 0)
    }

    private func bodyCenter(in frame: PoseFrame) -> PosePoint? {
        if let root = frame.joints[.root] { return root }
        guard let left = frame.joints[.leftHip], let right = frame.joints[.rightHip] else { return nil }
        return PosePoint(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2, confidence: min(left.confidence, right.confidence))
    }

    private func shoulderTilt(in frame: PoseFrame) -> Double? {
        guard let left = frame.joints[.leftShoulder], let right = frame.joints[.rightShoulder] else { return nil }
        return Geometry.lineAngle(left.point, right.point)
    }

    private func confidence(for frame: PoseFrame) -> ConfidenceLevel {
        frame.bodyConfidence >= 0.78 ? .high : (frame.bodyConfidence >= 0.52 ? .medium : .low)
    }

    private func minimumConfidence(_ lhs: ConfidenceLevel, _ rhs: ConfidenceLevel) -> ConfidenceLevel {
        let rank: [ConfidenceLevel: Int] = [.low: 0, .medium: 1, .high: 2]
        return (rank[lhs] ?? 0) <= (rank[rhs] ?? 0) ? lhs : rhs
    }
}
