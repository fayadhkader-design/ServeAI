import Foundation

struct PoseAmbiguityPolicy: Sendable {
    var blockingFrameRatio = 0.25
    var minimumBlockingFrames = 3

    func isBlocking(ambiguousFrames: Int, sampledFrames: Int) -> Bool {
        guard ambiguousFrames > 0, sampledFrames > 0 else { return false }
        let ratioThreshold = Int(
            ceil(Double(sampledFrames) * blockingFrameRatio)
        )
        return ambiguousFrames >= max(minimumBlockingFrames, ratioThreshold)
    }
}
