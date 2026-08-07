import CoreGraphics
import CoreML
import Foundation
import Vision

struct ExperimentalObjectPerceptionSummary: Codable, Hashable, Sendable {
    let modelIdentifier: String
    let confidenceThreshold: Double
    let sampledFrameCount: Int
    let directPoseFrameCount: Int
    let fallbackPoseFrameCount: Int
    let ballDetectedFrameCount: Int
    let racketDetectedFrameCount: Int

    var ballTrackCoverage: Double {
        Double(ballDetectedFrameCount) / Double(max(sampledFrameCount, 1))
    }

    var racketTrackCoverage: Double {
        Double(racketDetectedFrameCount) / Double(max(sampledFrameCount, 1))
    }
}

protocol ExperimentalObjectPerceptionAnalyzing: Sendable {
    func analyze(
        frames: [VideoFrame],
        poses: [PoseFrame],
        phases: [DetectedServePhase]
    ) async throws -> ExperimentalObjectPerceptionSummary
}

enum PoseCenteredObjectROI {
    static func rectangle(for pose: PoseFrame, imageWidth: Int, imageHeight: Int) -> CGRect? {
        let roots = [pose.joints[.root], pose.joints[.leftHip], pose.joints[.rightHip]]
            .compactMap { $0 }
            .filter { $0.confidence >= 0.15 }
        guard !roots.isEmpty, imageWidth > 0, imageHeight > 0 else { return nil }
        let rootX = roots.map(\.x).reduce(0, +) / Double(roots.count)
        let rootY = roots.map(\.y).reduce(0, +) / Double(roots.count)
        let scaleCandidates = [
            pose.joints[.nose], pose.joints[.neck],
            pose.joints[.leftAnkle], pose.joints[.rightAnkle]
        ].compactMap { $0 }.filter { $0.confidence >= 0.15 }
        let rawScale = max(
            scaleCandidates.map { hypot($0.x - rootX, $0.y - rootY) }.max() ?? 0,
            0.10
        )
        let width = Double(imageWidth)
        let height = Double(imageHeight)
        let side = min(width * 0.60, max(width * 0.40, rawScale * width * 5.0))
        let centerX = rootX * width
        let centerY = (1 - rootY) * height - side * 0.35
        let x = min(max(0, centerX - side / 2), width - side)
        let y = min(max(0, centerY - side / 2), height - side)
        return CGRect(x: x.rounded(), y: y.rounded(), width: side.rounded(), height: side.rounded())
    }
}

#if DEBUG
actor BundledExperimentalObjectPerceptionService: ExperimentalObjectPerceptionAnalyzing {
    static let modelResourceName = "ServeAIRacketBallPoseROIContextPilot"
    static let modelIdentifier = "serveai.racket-ball.pose-roi-context-pilot.v1"
    static let confidenceThreshold = 0.80

    private let visionModel: VNCoreMLModel

    init(bundle: Bundle = .main) throws {
        guard let modelURL = bundle.url(forResource: Self.modelResourceName, withExtension: "mlmodelc") else {
            throw ServeAIError.modelUnavailable("the Debug-only racket/ball pilot is not bundled")
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        visionModel = try VNCoreMLModel(for: MLModel(contentsOf: modelURL, configuration: configuration))
    }

    func analyze(
        frames: [VideoFrame],
        poses: [PoseFrame],
        phases: [DetectedServePhase]
    ) async throws -> ExperimentalObjectPerceptionSummary {
        guard !frames.isEmpty, !poses.isEmpty else {
            return ExperimentalObjectPerceptionSummary(
                modelIdentifier: Self.modelIdentifier,
                confidenceThreshold: Self.confidenceThreshold,
                sampledFrameCount: 0,
                directPoseFrameCount: 0,
                fallbackPoseFrameCount: 0,
                ballDetectedFrameCount: 0,
                racketDetectedFrameCount: 0
            )
        }
        let selectedFrames = criticalFrames(from: frames, phases: phases)
        let fallbackPose = medianFallbackPose(from: poses)
        var directPoseCount = 0
        var fallbackPoseCount = 0
        var ballCount = 0
        var racketCount = 0

        for frame in selectedFrames {
            try Task.checkCancellation()
            let nearest = poses.min { abs($0.timestamp - frame.timestamp) < abs($1.timestamp - frame.timestamp) }
            let pose: PoseFrame
            if let nearest, abs(nearest.timestamp - frame.timestamp) <= 0.12 {
                pose = nearest
                directPoseCount += 1
            } else {
                pose = fallbackPose
                fallbackPoseCount += 1
            }
            guard let roi = PoseCenteredObjectROI.rectangle(
                for: pose,
                imageWidth: frame.image.width,
                imageHeight: frame.image.height
            ), let crop = frame.image.cropping(to: roi) else { continue }
            let labels = try detectedLabels(in: crop)
            if labels.contains("tennis_ball") { ballCount += 1 }
            if labels.contains("tennis_racket") { racketCount += 1 }
        }
        return ExperimentalObjectPerceptionSummary(
            modelIdentifier: Self.modelIdentifier,
            confidenceThreshold: Self.confidenceThreshold,
            sampledFrameCount: selectedFrames.count,
            directPoseFrameCount: directPoseCount,
            fallbackPoseFrameCount: fallbackPoseCount,
            ballDetectedFrameCount: ballCount,
            racketDetectedFrameCount: racketCount
        )
    }

    private func detectedLabels(in image: CGImage) throws -> Set<String> {
        let request = VNCoreMLRequest(model: visionModel)
        request.imageCropAndScaleOption = .scaleFill
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        let observations = request.results as? [VNRecognizedObjectObservation] ?? []
        return Set(observations.flatMap { observation in
            observation.labels.compactMap { label in
                Double(label.confidence) >= Self.confidenceThreshold ? label.identifier : nil
            }
        })
    }

    private func criticalFrames(from frames: [VideoFrame], phases: [DetectedServePhase]) -> [VideoFrame] {
        let relevant = phases.filter {
            [.racketDrop, .upwardAcceleration, .contactPosition, .pronation].contains($0.phase)
        }
        let candidates: [VideoFrame]
        if let start = relevant.map(\.startTime).min(), let end = relevant.map(\.endTime).max() {
            candidates = frames.filter { $0.timestamp >= start - 0.12 && $0.timestamp <= end + 0.12 }
        } else {
            candidates = frames
        }
        guard candidates.count > 48 else { return candidates }
        let stride = Double(candidates.count - 1) / 47.0
        return (0..<48).map { candidates[Int((Double($0) * stride).rounded())] }
    }

    private func medianFallbackPose(from poses: [PoseFrame]) -> PoseFrame {
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            let middle = sorted.count / 2
            return sorted.count.isMultiple(of: 2)
                ? (sorted[middle - 1] + sorted[middle]) / 2
                : sorted[middle]
        }
        let roots = poses.compactMap { pose -> PosePoint? in
            let points = [pose.joints[.root], pose.joints[.leftHip], pose.joints[.rightHip]].compactMap { $0 }
            guard !points.isEmpty else { return nil }
            return PosePoint(
                x: points.map(\.x).reduce(0, +) / Double(points.count),
                y: points.map(\.y).reduce(0, +) / Double(points.count),
                confidence: points.map(\.confidence).reduce(0, +) / Double(points.count)
            )
        }
        guard !roots.isEmpty else { return poses[0] }
        let root = PosePoint(x: median(roots.map(\.x)), y: median(roots.map(\.y)), confidence: median(roots.map(\.confidence)))
        return PoseFrame(timestamp: poses.map(\.timestamp).reduce(0, +) / Double(poses.count), joints: [.root: root], bodyConfidence: root.confidence)
    }
}
#endif
