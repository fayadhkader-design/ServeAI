import XCTest
@testable import ServeAI

final class PoseAmbiguityPolicyTests: XCTestCase {
    func testSingleAmbiguousFrameDoesNotRejectClip() {
        let policy = PoseAmbiguityPolicy()

        XCTAssertFalse(
            policy.isBlocking(ambiguousFrames: 1, sampledFrames: 24)
        )
    }

    func testAmbiguityMustReachMinimumCountAndRatio() {
        let policy = PoseAmbiguityPolicy()

        XCTAssertFalse(
            policy.isBlocking(ambiguousFrames: 5, sampledFrames: 24)
        )
        XCTAssertTrue(
            policy.isBlocking(ambiguousFrames: 6, sampledFrames: 24)
        )
    }

    func testShortClipStillRequiresThreeAmbiguousFrames() {
        let policy = PoseAmbiguityPolicy()

        XCTAssertFalse(
            policy.isBlocking(ambiguousFrames: 2, sampledFrames: 8)
        )
        XCTAssertTrue(
            policy.isBlocking(ambiguousFrames: 3, sampledFrames: 8)
        )
    }

    func testEmptySampleNeverReportsSustainedAmbiguity() {
        let policy = PoseAmbiguityPolicy()

        XCTAssertFalse(
            policy.isBlocking(ambiguousFrames: 3, sampledFrames: 0)
        )
    }
}
