import Foundation

struct VideoClipSelection: Hashable, Sendable {
    static let minimumDuration: TimeInterval = 2
    static let maximumDuration: TimeInterval = 45

    let sourceURL: URL
    let startTime: TimeInterval?
    let endTime: TimeInterval?

    static func fullClip(_ url: URL) -> VideoClipSelection {
        VideoClipSelection(sourceURL: url, startTime: nil, endTime: nil)
    }

    var usesFullClip: Bool { startTime == nil && endTime == nil }

    var selectedDuration: TimeInterval? {
        guard let startTime, let endTime else { return nil }
        return endTime - startTime
    }

    func validated(sourceDuration: TimeInterval) throws -> ClosedRange<TimeInterval> {
        guard sourceDuration.isFinite, sourceDuration > 0 else {
            throw ServeAIError.corruptedVideo
        }

        let start = startTime ?? 0
        let end = endTime ?? sourceDuration
        guard start.isFinite, end.isFinite,
              start >= 0,
              end <= sourceDuration + 0.05,
              end > start else {
            throw ServeAIError.corruptedVideo
        }

        let duration = end - start
        guard duration >= Self.minimumDuration else {
            throw ServeAIError.videoTooShort
        }
        guard duration <= Self.maximumDuration else {
            throw ServeAIError.videoTooLong
        }
        return start...min(end, sourceDuration)
    }
}
