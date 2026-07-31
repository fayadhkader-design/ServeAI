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
           let angle = Geometry.robustPercentile(kneeSamples.map(\.angle), 0.20) {
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

        let wristSamples = frames.compactMap(wristElevationSample)
        if wristSamples.count >= 3,
           let height = Geometry.robustPercentile(wristSamples.map(\.height), 0.90) {
            let averageConfidence = wristSamples.map(\.confidence).reduce(0, +)
                / Double(wristSamples.count)
            metrics.append(TechnicalMetric(
                title: "Peak visible wrist elevation",
                value: String(format: "%.2f torso lengths", height),
                context: "Robust wrist height above its shoulder; this is not ball-contact or racket-head height.",
                confidence: level(averageConfidence),
                relatedPhase: .contactPosition
            ))
        }

        let centerSamples = frames.compactMap(bodyCenterSample)
        if centerSamples.count >= 4 {
            let edgeCount = max(2, centerSamples.count / 5)
            let firstSamples = Array(centerSamples.prefix(edgeCount))
            let lastSamples = Array(centerSamples.suffix(edgeCount))
            if let firstCenter = Geometry.percentile(firstSamples.map(\.x), 0.50),
               let lastCenter = Geometry.percentile(lastSamples.map(\.x), 0.50),
               let scale = Geometry.percentile(centerSamples.map(\.scale), 0.50),
               scale > 0.04 {
                let displacement = (lastCenter - firstCenter) / scale
                let averageConfidence = centerSamples.map(\.confidence).reduce(0, +)
                    / Double(centerSamples.count)
                metrics.append(TechnicalMetric(
                    title: "Center movement",
                    value: String(format: "%+.2f torso lengths", displacement),
                    context: "Robust horizontal travel from setup through recovery; direction depends on the selected camera view.",
                    confidence: level(averageConfidence),
                    relatedPhase: .landingFollowThrough
                ))
            }
        }

        if cameraAngle == .rear {
            let trophyFrames = framesFor(.trophyPosition, in: frames, phases: phases)
            let tiltSamples = trophyFrames.compactMap(shoulderTilt)
            if tiltSamples.count >= 3,
               let tilt = Geometry.robustPercentile(tiltSamples.map(\.angle), 0.80),
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

    private func wristElevationSample(in frame: PoseFrame) -> (height: Double, confidence: Double)? {
        let pairs: [(BodyJoint, BodyJoint)] = [
            (.leftShoulder, .leftWrist),
            (.rightShoulder, .rightWrist)
        ]
        guard let scale = torsoScale(in: frame), scale > 0.04 else { return nil }
        return pairs.compactMap { shoulderJoint, wristJoint -> (Double, Double)? in
            guard let shoulder = frame.joints[shoulderJoint],
                  let wrist = frame.joints[wristJoint] else {
                return nil
            }
            let confidence = min(shoulder.confidence, wrist.confidence)
            guard confidence >= 0.35 else { return nil }
            return ((wrist.y - shoulder.y) / scale, confidence)
        }.max(by: { $0.0 < $1.0 }).map { ($0.0, $0.1) }
    }

    private func bodyCenterSample(in frame: PoseFrame) -> (x: Double, scale: Double, confidence: Double)? {
        guard let scale = torsoScale(in: frame), scale > 0.04 else { return nil }
        if let root = frame.joints[.root], root.confidence >= 0.35 {
            return (root.x, scale, root.confidence)
        }
        guard let left = frame.joints[.leftHip],
              let right = frame.joints[.rightHip],
              min(left.confidence, right.confidence) >= 0.35 else {
            return nil
        }
        return (
            (left.x + right.x) / 2,
            scale,
            min(left.confidence, right.confidence)
        )
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
        guard let interval = phases.first(where: { $0.phase == phase }),
              interval.confidence >= 0.35 else {
            return []
        }
        return frames.filter { $0.timestamp >= interval.startTime && $0.timestamp <= interval.endTime }
    }

    private func level(_ value: Double) -> ConfidenceLevel {
        value >= 0.78 ? .high : (value >= 0.52 ? .medium : .low)
    }
}
