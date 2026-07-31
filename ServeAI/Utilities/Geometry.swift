import CoreGraphics
import Foundation

enum Geometry {
    static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        hypot(Double(b.x - a.x), Double(b.y - a.y))
    }

    static func normalizedDistance(_ a: CGPoint, _ b: CGPoint, referenceLength: Double) -> Double? {
        guard referenceLength > .ulpOfOne else { return nil }
        return distance(a, b) / referenceLength
    }

    static func angle(vertex: CGPoint, first: CGPoint, second: CGPoint) -> Double? {
        let vectorA = CGVector(dx: first.x - vertex.x, dy: first.y - vertex.y)
        let vectorB = CGVector(dx: second.x - vertex.x, dy: second.y - vertex.y)
        let magnitude = hypot(vectorA.dx, vectorA.dy) * hypot(vectorB.dx, vectorB.dy)
        guard magnitude > .ulpOfOne else { return nil }
        let cosine = max(-1, min(1, (vectorA.dx * vectorB.dx + vectorA.dy * vectorB.dy) / magnitude))
        return acos(cosine) * 180 / .pi
    }

    static func lineAngle(_ a: CGPoint, _ b: CGPoint) -> Double {
        atan2(Double(b.y - a.y), Double(b.x - a.x)) * 180 / .pi
    }

    /// Returns the unsigned angle between an unoriented line and horizontal.
    /// A shoulder line has no meaningful "forward" direction, so 107° and -73°
    /// describe the same 73° image-plane tilt.
    static func acuteLineTilt(_ a: CGPoint, _ b: CGPoint) -> Double {
        var angle = abs(lineAngle(a, b)).truncatingRemainder(dividingBy: 180)
        if angle > 90 { angle = 180 - angle }
        return angle
    }

    static func percentile(_ values: [Double], _ probability: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let bounded = max(0, min(1, probability))
        let position = bounded * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))
        guard lower != upper else { return sorted[lower] }
        let fraction = position - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
    }

    /// A percentile that cannot select either endpoint when at least three
    /// samples exist. This prevents one pose spike from becoming a phase peak.
    static func robustPercentile(_ values: [Double], _ probability: Double) -> Double? {
        guard values.count >= 3 else { return percentile(values, probability) }
        let endpointStep = 1 / Double(values.count - 1)
        return percentile(
            values,
            max(endpointStep, min(1 - endpointStep, probability))
        )
    }

    static func velocity(from a: CGPoint, at firstTime: TimeInterval, to b: CGPoint, at secondTime: TimeInterval) -> CGVector? {
        let delta = secondTime - firstTime
        guard delta > .ulpOfOne else { return nil }
        return CGVector(dx: Double(b.x - a.x) / delta, dy: Double(b.y - a.y) / delta)
    }

    static func movingAverage(_ values: [Double], window: Int) -> [Double] {
        guard window > 1, values.count > 1 else { return values }
        return values.indices.map { index in
            let lower = max(0, index - window / 2)
            let upper = min(values.count - 1, index + window / 2)
            let slice = values[lower...upper]
            return slice.reduce(0, +) / Double(slice.count)
        }
    }

    static func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }
}
