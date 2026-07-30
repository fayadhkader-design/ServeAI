import Foundation

enum ServeAIError: LocalizedError, Identifiable {
    case cameraPermissionDenied
    case photoLibraryUnavailable
    case unsupportedVideo
    case videoTooShort
    case videoTooLong
    case noPersonDetected
    case multiplePeopleDetected
    case playerOutsideFrame
    case poseRuntimeUnavailable
    case poseTrackingFailed
    case analysisCanceled
    case insufficientStorage
    case corruptedVideo
    case videoDeletionFailed(String)
    case modelUnavailable(String)
    case recordingFailed(String)
    case persistenceFailed(String)
    case coachTaskImportFailed(String)

    var id: String { errorDescription ?? String(describing: self) }

    var errorDescription: String? {
        switch self {
        case .cameraPermissionDenied: "Camera access is off"
        case .photoLibraryUnavailable: "Photo library is unavailable"
        case .unsupportedVideo: "This video format is not supported"
        case .videoTooShort: "The clip is too short"
        case .videoTooLong: "The clip is too long"
        case .noPersonDetected: "No player was detected"
        case .multiplePeopleDetected: "Multiple foreground players were detected"
        case .playerOutsideFrame: "The player is outside the frame"
        case .poseRuntimeUnavailable: "Body tracking is unavailable in this runtime"
        case .poseTrackingFailed: "Body tracking could not be completed"
        case .analysisCanceled: "Analysis was canceled"
        case .insufficientStorage: "Not enough storage is available"
        case .corruptedVideo: "The video could not be read"
        case .videoDeletionFailed: "The report was deleted, but its private video copy could not be removed"
        case .modelUnavailable(let message): "The trained analysis model is unavailable: \(message)"
        case .recordingFailed(let message): "Recording failed: \(message)"
        case .persistenceFailed(let message): "Could not save the analysis: \(message)"
        case .coachTaskImportFailed(let message): "Could not import the coach task: \(message)"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .cameraPermissionDenied: "Open Settings, allow Camera access for ServeAI, then return to record."
        case .photoLibraryUnavailable: "Check Photos access in Settings or record a new video."
        case .unsupportedVideo, .corruptedVideo: "Choose a standard HEVC or H.264 video from Photos."
        case .videoDeletionFailed: "Restart ServeAI to retry automatic private-file cleanup."
        case .videoTooShort: "Choose a clip that includes one complete serve and is at least two seconds long."
        case .videoTooLong: "Trim the clip to one serve under 45 seconds, then try again."
        case .noPersonDetected, .playerOutsideFrame: "Use a well-lit side or rear view with the full body visible."
        case .multiplePeopleDetected: "Crop or re-record so one foreground player is clearly dominant. Distant spectators do not need to be removed."
        case .poseRuntimeUnavailable: "Run ServeAI on a physical iPhone. This Simulator does not include Apple Vision's body-pose model."
        case .poseTrackingFailed: "Try a steadier, brighter clip with less obstruction."
        case .analysisCanceled: "Return to the review screen when you are ready to try again."
        case .insufficientStorage: "Free some device storage, then retry."
        case .modelUnavailable: "Switch to the Vision development mode or install a signed, validated ServeAI model bundle."
        case .recordingFailed: "Retake the video or choose one from Photos."
        case .persistenceFailed: "The report is still visible; retry saving after freeing storage."
        case .coachTaskImportFailed: "Choose the signed task JSON and the exact original video, then try again."
        }
    }
}
