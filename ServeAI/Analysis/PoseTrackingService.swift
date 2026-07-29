import Foundation

protocol PoseTrackingService: Sendable {
    func smooth(_ frames: [PoseFrame], window: Int) -> [PoseFrame]
}

struct MovingAveragePoseTrackingService: PoseTrackingService {
    func smooth(_ frames: [PoseFrame], window: Int = 5) -> [PoseFrame] {
        guard frames.count > 2, window > 1 else { return frames }
        var result = frames
        for joint in BodyJoint.allCases {
            let indices = frames.indices.filter { frames[$0].joints[joint] != nil }
            let xs = indices.compactMap { frames[$0].joints[joint]?.x }
            let ys = indices.compactMap { frames[$0].joints[joint]?.y }
            let smoothX = Geometry.movingAverage(xs, window: window)
            let smoothY = Geometry.movingAverage(ys, window: window)
            for (offset, frameIndex) in indices.enumerated() {
                guard let original = result[frameIndex].joints[joint] else { continue }
                var joints = result[frameIndex].joints
                joints[joint] = PosePoint(x: smoothX[offset], y: smoothY[offset], confidence: original.confidence)
                result[frameIndex] = PoseFrame(id: result[frameIndex].id, timestamp: result[frameIndex].timestamp, joints: joints, bodyConfidence: result[frameIndex].bodyConfidence)
            }
        }
        return result
    }
}
