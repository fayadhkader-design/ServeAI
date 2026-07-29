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
    var provenanceVersion: String { "revision-\(VNDetectHumanBodyPoseRequest.currentRevision)" }

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
        return try await Task.detached(priority: .userInitiated) { () throws -> PoseFrame? in
            let request = VNDetectHumanBodyPoseRequest()
            request.revision = VNDetectHumanBodyPoseRequest.currentRevision
            let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
            try handler.perform([request])
            guard let observations = request.results, !observations.isEmpty else { return nil }
            guard observations.count == 1 else { throw ServeAIError.multiplePeopleDetected }
            let recognized = try observations[0].recognizedPoints(.all)
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
                guard let point = recognized[visionName], point.confidence >= 0.15 else { continue }
                joints[joint] = PosePoint(x: point.location.x, y: point.location.y, confidence: Double(point.confidence))
            }
            guard joints.count >= 6 else { return nil }
            let confidence = joints.values.reduce(0) { $0 + $1.confidence } / Double(joints.count)
            return PoseFrame(timestamp: timestamp, joints: joints, bodyConfidence: confidence)
        }.value
    }
}
