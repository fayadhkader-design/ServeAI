import XCTest
@testable import ServeAI

final class ServeAIErrorTests: XCTestCase {
    func testPoseRuntimeUnavailableDoesNotBlameTheRecording() {
        let error = ServeAIError.poseRuntimeUnavailable

        XCTAssertEqual(error.errorDescription, "Body tracking is unavailable in this runtime")
        XCTAssertEqual(
            error.recoverySuggestion,
            "Run ServeAI on a physical iPhone. This Simulator does not include Apple Vision's body-pose model."
        )
        XCTAssertFalse(error.recoverySuggestion?.contains("steadier") == true)
        XCTAssertFalse(error.recoverySuggestion?.contains("brighter") == true)
    }

    func testVisionPoseDetectorDeclaresSimulatorUnsupported() {
        #if targetEnvironment(simulator)
        XCTAssertFalse(VisionBodyPoseDetectionService.isSupportedRuntime)
        #else
        XCTAssertTrue(VisionBodyPoseDetectionService.isSupportedRuntime)
        #endif
    }
}
