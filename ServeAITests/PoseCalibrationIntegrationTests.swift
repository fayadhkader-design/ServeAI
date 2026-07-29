import CryptoKit
import XCTest
@testable import ServeAI

final class PoseCalibrationIntegrationTests: XCTestCase {
    private struct CalibrationCase {
        let clipID: String
        let expectedSHA256: String
    }

    private struct CalibrationResult: Codable {
        let clipID: String
        let sha256: String
        let runtime: String
        let status: RecordingQualityStatus
        let poseFrameCount: Int
        let sampledFrameCount: Int
        let poseCoverage: Double
        let meanPoseConfidence: Double
        let fullBodyCoverage: Double
        let edgeClippingRatio: Double
        let issues: [RecordingQualityIssue]
    }

    func testPoseCropCalibrationEvidence() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip(
            "Apple Vision body-pose inference is unavailable in this Simulator runtime "
                + "(cnn_human_pose.espresso.weights is missing). Run this test on a physical iPhone."
        )
        #endif

        let cases = [
            CalibrationCase(
                clipID: "IMG_6105-A-pose-crop",
                expectedSHA256: "6d17b3b35bbab1f6d28878cfb5870d4968b77415ef4d74132f2e0ffece0d9b3b"
            ),
            CalibrationCase(
                clipID: "IMG_6106-A-pose-crop",
                expectedSHA256: "1949cc1e5091712e7a3c6496bdb20c3ad5cdc562c262582ab08a18e007156a16"
            ),
        ]
        let assessor = VisionRecordingQualityAssessor()
        var results: [CalibrationResult] = []

        for calibrationCase in cases {
            let url = try XCTUnwrap(resourceURL(named: calibrationCase.clipID))
            let data = try Data(contentsOf: url)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(digest, calibrationCase.expectedSHA256)

            let report = try await assessor.assess(videoURL: url, cameraAngle: .rear)
            results.append(CalibrationResult(
                clipID: calibrationCase.clipID,
                sha256: digest,
                runtime: "iOS Simulator calibration only; not physical-device release evidence",
                status: report.status,
                poseFrameCount: report.poseFrameCount,
                sampledFrameCount: report.metadata.sampledFrames,
                poseCoverage: report.poseCoverage,
                meanPoseConfidence: report.meanPoseConfidence,
                fullBodyCoverage: report.fullBodyCoverage,
                edgeClippingRatio: report.edgeClippingRatio,
                issues: report.issues
            ))
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let evidence = try encoder.encode(results)
        let attachment = XCTAttachment(data: evidence, uniformTypeIdentifier: "public.json")
        attachment.name = "serveai-pose-crop-calibration-results"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("POSE_CALIBRATION_RESULTS \(String(decoding: evidence, as: UTF8.self))")
    }

    private func resourceURL(named name: String) -> URL? {
        let bundle = Bundle(for: Self.self)
        return bundle.url(forResource: name, withExtension: "mp4", subdirectory: "Fixtures")
            ?? bundle.url(forResource: name, withExtension: "mp4")
    }
}
