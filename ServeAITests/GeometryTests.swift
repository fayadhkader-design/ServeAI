import CoreGraphics
import XCTest
@testable import ServeAI

final class GeometryTests: XCTestCase {
    func testRightAngleCalculation() {
        let angle = Geometry.angle(vertex: .zero, first: CGPoint(x: 1, y: 0), second: CGPoint(x: 0, y: 1))
        XCTAssertEqual(angle ?? -1, 90, accuracy: 0.0001)
    }

    func testStraightAngleCalculation() {
        let angle = Geometry.angle(vertex: .zero, first: CGPoint(x: -1, y: 0), second: CGPoint(x: 1, y: 0))
        XCTAssertEqual(angle ?? -1, 180, accuracy: 0.0001)
    }

    func testNormalizedDistance() {
        let normalized = Geometry.normalizedDistance(.zero, CGPoint(x: 3, y: 4), referenceLength: 10)
        XCTAssertEqual(normalized ?? -1, 0.5, accuracy: 0.0001)
        XCTAssertNil(Geometry.normalizedDistance(.zero, CGPoint(x: 1, y: 1), referenceLength: 0))
    }

    func testMovingAverageKeepsCountAndSmoothsPeak() {
        let result = Geometry.movingAverage([0, 0, 9, 0, 0], window: 3)
        XCTAssertEqual(result.count, 5)
        XCTAssertEqual(result[2], 3, accuracy: 0.0001)
    }
}
