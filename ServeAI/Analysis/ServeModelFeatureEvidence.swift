import CryptoKit
import Foundation

struct ServeModelJointFeature: Codable, Hashable, Sendable {
    let joint: BodyJoint
    let x: Double
    let y: Double
    let confidence: Double
    let isPresent: Bool
}

struct ServeModelFrameFeature: Codable, Hashable, Sendable {
    let timestamp: TimeInterval
    let bodyConfidence: Double
    let joints: [ServeModelJointFeature]

    func feature(for joint: BodyJoint) -> ServeModelJointFeature? {
        joints.first { $0.joint == joint }
    }
}

struct ServeModelFeatureSequence: Codable, Hashable, Sendable {
    static let schemaVersion = 2

    let schemaVersion: Int
    let duration: TimeInterval
    let cameraAngle: CameraAngle
    let frames: [ServeModelFrameFeature]

    init(duration: TimeInterval, cameraAngle: CameraAngle, frames: [ServeModelFrameFeature]) {
        schemaVersion = Self.schemaVersion
        self.duration = duration
        self.cameraAngle = cameraAngle
        self.frames = frames
    }

    var isCompleteForDataset: Bool {
        guard schemaVersion == Self.schemaVersion,
              duration.isFinite,
              duration >= 2,
              duration <= 45,
              frames.count >= 18,
              let firstTime = frames.first?.timestamp,
              let lastTime = frames.last?.timestamp,
              firstTime.isFinite,
              lastTime.isFinite,
              firstTime >= 0,
              lastTime <= duration + 0.1,
              lastTime > firstTime else { return false }

        var previousTime = -Double.infinity
        for frame in frames {
            guard frame.timestamp.isFinite,
                  frame.timestamp >= previousTime,
                  frame.bodyConfidence.isFinite,
                  (0...1).contains(frame.bodyConfidence),
                  frame.joints.count == BodyJoint.allCases.count,
                  Set(frame.joints.map(\.joint)) == Set(BodyJoint.allCases) else { return false }
            previousTime = frame.timestamp
            for feature in frame.joints {
                guard feature.x.isFinite,
                      feature.y.isFinite,
                      feature.confidence.isFinite,
                      abs(feature.x) <= 10,
                      abs(feature.y) <= 10,
                      (0...1).contains(feature.confidence) else { return false }
                if !feature.isPresent,
                   feature.x != 0 || feature.y != 0 || feature.confidence != 0 {
                    return false
                }
            }
        }
        return true
    }
}

struct ServeModelFeatureProvenance: Codable, Hashable, Sendable {
    static let schemaVersion = 1
    static let encoderIdentifier = "serveai.pose-sequence"
    static let encoderVersion = "2.0.0"

    let schemaVersion: Int
    let encoderIdentifier: String
    let encoderVersion: String
    let poseDetectorIdentifier: String
    let poseDetectorVersion: String
    let videoSHA256: String
    let generatedAt: Date
    let requestedSamplesPerSecond: Double
    let smoothingWindow: Int
    let sampledFrameCount: Int
    let detectedFrameCount: Int

    init(
        poseDetectorIdentifier: String,
        poseDetectorVersion: String,
        videoSHA256: String,
        generatedAt: Date = .now,
        requestedSamplesPerSecond: Double,
        smoothingWindow: Int,
        sampledFrameCount: Int,
        detectedFrameCount: Int
    ) {
        schemaVersion = Self.schemaVersion
        encoderIdentifier = Self.encoderIdentifier
        encoderVersion = Self.encoderVersion
        self.poseDetectorIdentifier = poseDetectorIdentifier
        self.poseDetectorVersion = poseDetectorVersion
        self.videoSHA256 = videoSHA256.lowercased()
        self.generatedAt = generatedAt
        self.requestedSamplesPerSecond = requestedSamplesPerSecond
        self.smoothingWindow = smoothingWindow
        self.sampledFrameCount = sampledFrameCount
        self.detectedFrameCount = detectedFrameCount
    }

    var isCompleteForDataset: Bool {
        schemaVersion == Self.schemaVersion
            && encoderIdentifier == Self.encoderIdentifier
            && encoderVersion == Self.encoderVersion
            && !poseDetectorIdentifier.isEmpty
            && !poseDetectorVersion.isEmpty
            && videoSHA256.count == 64
            && videoSHA256.allSatisfy(\.isHexDigit)
            && requestedSamplesPerSecond > 0
            && smoothingWindow > 0
            && sampledFrameCount >= detectedFrameCount
            && detectedFrameCount >= 18
    }
}

struct ServeModelFeatureEvidence: Codable, Hashable, Sendable {
    let sequence: ServeModelFeatureSequence
    let provenance: ServeModelFeatureProvenance

    var isCompleteForDataset: Bool {
        sequence.isCompleteForDataset
            && provenance.isCompleteForDataset
            && provenance.detectedFrameCount == sequence.frames.count
    }
}

protocol VideoContentHashing: Sendable {
    func sha256(of url: URL) async throws -> String
}

struct SHA256VideoContentHasher: VideoContentHashing {
    func sha256(of url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }
}

struct ServeModelFeatureEncoder: Sendable {
    func encode(frames: [PoseFrame], duration: TimeInterval, cameraAngle: CameraAngle) -> ServeModelFeatureSequence {
        let encoded = frames.map { frame in
            let center = bodyCenter(frame)
            let scale = bodyScale(frame, center: center)
            let joints = BodyJoint.allCases.map { joint in
                guard let point = frame.joints[joint] else {
                    return ServeModelJointFeature(joint: joint, x: 0, y: 0, confidence: 0, isPresent: false)
                }
                return ServeModelJointFeature(
                    joint: joint,
                    x: (point.x - center.x) / scale,
                    y: (point.y - center.y) / scale,
                    confidence: point.confidence,
                    isPresent: true
                )
            }
            return ServeModelFrameFeature(
                timestamp: frame.timestamp,
                bodyConfidence: frame.bodyConfidence,
                joints: joints
            )
        }
        return ServeModelFeatureSequence(duration: duration, cameraAngle: cameraAngle, frames: encoded)
    }

    private func bodyCenter(_ frame: PoseFrame) -> (x: Double, y: Double) {
        let candidates = [frame.joints[.root], frame.joints[.leftHip], frame.joints[.rightHip]].compactMap { $0 }
        guard !candidates.isEmpty else { return (0.5, 0.5) }
        return (
            candidates.map(\.x).reduce(0, +) / Double(candidates.count),
            candidates.map(\.y).reduce(0, +) / Double(candidates.count)
        )
    }

    private func bodyScale(_ frame: PoseFrame, center: (x: Double, y: Double)) -> Double {
        let points = [
            frame.joints[.nose], frame.joints[.neck],
            frame.joints[.leftAnkle], frame.joints[.rightAnkle]
        ].compactMap { $0 }
        let distances = points.map { hypot($0.x - center.x, $0.y - center.y) }
        return max(distances.max() ?? 0, 0.10)
    }
}
