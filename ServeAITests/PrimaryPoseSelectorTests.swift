import XCTest
@testable import ServeAI

final class PrimaryPoseSelectorTests: XCTestCase {
    func testSelectsLargeServerAndIgnoresSmallStadiumSpectators() throws {
        let server = pose(
            originX: 0.31,
            originY: 0.12,
            width: 0.28,
            height: 0.62,
            confidence: 0.82
        )
        let spectators = (0..<12).map { index in
            pose(
                originX: 0.03 + Double(index % 6) * 0.15,
                originY: 0.80 + Double(index / 6) * 0.08,
                width: 0.055,
                height: 0.09,
                confidence: 0.94
            )
        }

        let result = PrimaryPoseSelector().select(from: spectators + [server])

        guard case .selected(let selected) = result else {
            return XCTFail("Expected a dominant server pose")
        }
        XCTAssertEqual(selected.id, server.id)
    }

    func testGeometryOutweighsTinyHighConfidenceBackgroundPose() throws {
        let server = pose(
            originX: 0.34,
            originY: 0.12,
            width: 0.25,
            height: 0.58,
            confidence: 0.58
        )
        let spectator = pose(
            originX: 0.10,
            originY: 0.82,
            width: 0.06,
            height: 0.10,
            confidence: 0.99
        )

        let result = PrimaryPoseSelector().select(from: [spectator, server])

        guard case .selected(let selected) = result else {
            return XCTFail("Expected the foreground athlete")
        }
        XCTAssertEqual(selected.id, server.id)
    }

    func testRejectsTwoComparableForegroundPlayersAsAmbiguous() {
        let server = pose(
            originX: 0.18,
            originY: 0.12,
            width: 0.25,
            height: 0.60,
            confidence: 0.88
        )
        let secondPlayer = pose(
            originX: 0.56,
            originY: 0.14,
            width: 0.23,
            height: 0.56,
            confidence: 0.84
        )

        let result = PrimaryPoseSelector().select(from: [server, secondPlayer])

        guard case .ambiguous = result else {
            return XCTFail("Comparable foreground athletes must remain ambiguous")
        }
    }

    func testIgnoresIncompleteCandidate() throws {
        let server = pose(
            originX: 0.35,
            originY: 0.14,
            width: 0.24,
            height: 0.56,
            confidence: 0.90
        )
        let incomplete = PoseFrame(
            timestamp: 0,
            joints: [
                .nose: .init(x: 0.1, y: 0.9, confidence: 0.99),
                .neck: .init(x: 0.1, y: 0.88, confidence: 0.99),
            ],
            bodyConfidence: 0.99
        )

        let result = PrimaryPoseSelector().select(from: [incomplete, server])

        guard case .selected(let selected) = result else {
            return XCTFail("Expected the complete athlete pose")
        }
        XCTAssertEqual(selected.id, server.id)
    }

    func testReturnsNoneWithoutUsablePose() {
        let result = PrimaryPoseSelector().select(from: [])

        guard case .none = result else {
            return XCTFail("Empty candidates should not produce a pose")
        }
    }

    private func pose(
        originX: Double,
        originY: Double,
        width: Double,
        height: Double,
        confidence: Double
    ) -> PoseFrame {
        let joints = Dictionary(
            uniqueKeysWithValues: BodyJoint.allCases.enumerated().map { index, joint in
                let column = Double(index % 4) / 3
                let row = Double(index / 4) / 3
                return (
                    joint,
                    PosePoint(
                        x: originX + width * column,
                        y: originY + height * row,
                        confidence: confidence
                    )
                )
            }
        )
        return PoseFrame(
            timestamp: 0,
            joints: joints,
            bodyConfidence: confidence
        )
    }
}
