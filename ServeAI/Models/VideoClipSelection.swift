import Foundation

struct VideoClipSelection: Hashable, Sendable {
    let sourceURL: URL
    let startTime: TimeInterval?
    let endTime: TimeInterval?

    static func fullClip(_ url: URL) -> VideoClipSelection {
        VideoClipSelection(sourceURL: url, startTime: nil, endTime: nil)
    }

    var usesFullClip: Bool { startTime == nil && endTime == nil }
}
