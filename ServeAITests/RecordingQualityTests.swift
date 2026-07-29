import XCTest
@testable import ServeAI

final class RecordingQualityTests: XCTestCase {
    private let metadata = VideoMetadata(
        duration: 7,
        width: 1920,
        height: 1080,
        nominalFrameRate: 60,
        usableFrames: 10,
        sampledFrames: 10
    )

    func testHighQualityRecordingPassesGate() {
        let frames = (0..<10).map { fullBodyFrame(timestamp: Double($0) / 3) }

        let report = RecordingQualityEvaluator().evaluate(metadata: metadata, poseFrames: frames)

        XCTAssertEqual(report.status, .ready)
        XCTAssertTrue(report.isAcceptable)
        XCTAssertEqual(report.poseCoverage, 1, accuracy: 0.001)
        XCTAssertEqual(report.fullBodyCoverage, 1, accuracy: 0.001)
        XCTAssertTrue(report.issues.isEmpty)
    }

    func testPoorTrackingAndVisibilityRejectRecording() {
        let partial = PoseFrame(
            timestamp: 0,
            joints: [
                .nose: .init(x: 0.5, y: 0.8, confidence: 0.8),
                .neck: .init(x: 0.5, y: 0.7, confidence: 0.8),
                .leftShoulder: .init(x: 0.4, y: 0.65, confidence: 0.8),
                .rightShoulder: .init(x: 0.6, y: 0.65, confidence: 0.8),
                .leftHip: .init(x: 0.45, y: 0.45, confidence: 0.8),
                .rightHip: .init(x: 0.55, y: 0.45, confidence: 0.8)
            ],
            bodyConfidence: 0.8
        )

        let report = RecordingQualityEvaluator().evaluate(metadata: metadata, poseFrames: [partial, partial])

        XCTAssertEqual(report.status, .rejected)
        XCTAssertFalse(report.isAcceptable)
        XCTAssertTrue(report.issues.contains { $0.kind == .playerDetection && $0.severity == .blocking })
        XCTAssertTrue(report.issues.contains { $0.kind == .fullBodyVisibility && $0.severity == .blocking })
    }

    func testMultiplePeopleIsAlwaysBlocking() {
        let issue = RecordingQualityIssue(
            kind: .multiplePeople,
            severity: .blocking,
            title: "Multiple people",
            detail: "Two people found",
            recovery: "Record one player"
        )

        let report = RecordingQualityEvaluator().evaluate(
            metadata: metadata,
            poseFrames: (0..<10).map { fullBodyFrame(timestamp: Double($0)) },
            additionalIssues: [issue]
        )

        XCTAssertEqual(report.status, .rejected)
        XCTAssertTrue(report.issues.contains { $0.kind == .multiplePeople })
    }

#if DEBUG
    func testAcceptancePreviewQualityGateIsReady() async throws {
        let report = try await AcceptancePreviewRecordingQualityAssessor().assess(
            videoURL: URL(fileURLWithPath: "/tmp/acceptance-fixture.mov"),
            cameraAngle: .rear
        )

        XCTAssertEqual(report.status, .ready)
        XCTAssertTrue(report.isAcceptable)
        XCTAssertEqual(report.poseCoverage, 1)
        XCTAssertEqual(report.fullBodyCoverage, 1)
        XCTAssertTrue(report.issues.isEmpty)
    }
#endif

    private func fullBodyFrame(timestamp: TimeInterval) -> PoseFrame {
        let joints = Dictionary(uniqueKeysWithValues: BodyJoint.allCases.map { joint in
            let index = Double(jointIndex(joint))
            return (joint, PosePoint(x: 0.30 + index * 0.025, y: 0.20 + index * 0.035, confidence: 0.92))
        })
        return PoseFrame(timestamp: timestamp, joints: joints, bodyConfidence: 0.92)
    }

    private func jointIndex(_ joint: BodyJoint) -> Int {
        BodyJoint.allCases.firstIndex(of: joint) ?? 0
    }
}
