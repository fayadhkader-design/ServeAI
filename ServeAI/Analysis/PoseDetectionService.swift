import CoreGraphics
import Foundation
import Vision

protocol PoseDetectionService: Sendable {
    var provenanceIdentifier: String { get }
    var provenanceVersion: String { get }
    func detectPose(in image: CGImage, at timestamp: TimeInterval) async throws -> PoseFrame?
}

extension PoseDetectionService {
    var provenanceIdentifier: String { "unspecified-pose-detector" }
    var provenanceVersion: String { "unspecified" }
}

struct VisionBodyPoseDetectionService: PoseDetectionService {
    let provenanceIdentifier = "AppleVision.VNDetectHumanBodyPoseRequest"
    var provenanceVersion: String {
        "revision-\(VNDetectHumanBodyPoseRequest.currentRevision)-primary-athlete-v1"
    }
    private let selector: PrimaryPoseSelector

    init(selector: PrimaryPoseSelector = PrimaryPoseSelector()) {
        self.selector = selector
    }

    static var isSupportedRuntime: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }

    func detectPose(in image: CGImage, at timestamp: TimeInterval) async throws -> PoseFrame? {
        guard Self.isSupportedRuntime else {
            throw ServeAIError.poseRuntimeUnavailable
        }
        let selector = selector
        return try await Task.detached(priority: .userInitiated) { () throws -> PoseFrame? in
            let request = VNDetectHumanBodyPoseRequest()
            request.revision = VNDetectHumanBodyPoseRequest.currentRevision
            let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
            try handler.perform([request])
            guard let observations = request.results, !observations.isEmpty else { return nil }
            let candidates = try observations.compactMap {
                try Self.poseFrame(from: $0, timestamp: timestamp)
            }

            switch selector.select(from: candidates) {
            case .none:
                return nil
            case .selected(let pose):
                return pose
            case .ambiguous:
                throw ServeAIError.multiplePeopleDetected
            }
        }.value
    }

    private static func poseFrame(
        from observation: VNHumanBodyPoseObservation,
        timestamp: TimeInterval
    ) throws -> PoseFrame? {
        let recognized = try observation.recognizedPoints(.all)
        let mapping: [(BodyJoint, VNHumanBodyPoseObservation.JointName)] = [
            (.nose, .nose), (.neck, .neck), (.root, .root),
            (.leftShoulder, .leftShoulder), (.rightShoulder, .rightShoulder),
            (.leftElbow, .leftElbow), (.rightElbow, .rightElbow),
            (.leftWrist, .leftWrist), (.rightWrist, .rightWrist),
            (.leftHip, .leftHip), (.rightHip, .rightHip),
            (.leftKnee, .leftKnee), (.rightKnee, .rightKnee),
            (.leftAnkle, .leftAnkle), (.rightAnkle, .rightAnkle)
        ]
        var joints: [BodyJoint: PosePoint] = [:]
        for (joint, visionName) in mapping {
            guard let point = recognized[visionName],
                  point.confidence >= 0.15 else {
                continue
            }
            joints[joint] = PosePoint(
                x: point.location.x,
                y: point.location.y,
                confidence: Double(point.confidence)
            )
        }
        guard joints.count >= 6 else { return nil }
        let confidence = joints.values.reduce(0) { $0 + $1.confidence }
            / Double(joints.count)
        return PoseFrame(
            timestamp: timestamp,
            joints: joints,
            bodyConfidence: confidence
        )
    }
}
