import Foundation
import CoreGraphics

public struct PositionPathFeatures: Sendable {
    /// Signed inverse millimetres. A straight or insufficiently long path
    /// has zero or unavailable curvature, respectively.
    public let relativeCurvature: Double?
    public let contactCurvatures: [Double?]
    public let relativeBend: Double?
    public let relativeTravel: Double
    public let rotationSupport: Double
}

/// Causal, position-only path geometry. A short low-pass filter and minimum
/// chord lengths prevent ellipse-axis quantization or submillimetre jitter
/// from becoming a curvature derivative. The joint relative path supplies
/// evidence; a curved thumb-candidate path alone cannot establish a turn.
struct PositionPathEvidence: Sendable {
    private struct Sample: Sendable {
        let time: TimeInterval
        let points: [CGPoint]
        var relative: CGPoint { CGPoint(x: points[1].x - points[0].x, y: points[1].y - points[0].y) }
    }
    private var samples: [Sample] = []
    private var filtered: [CGPoint] = []
    private var previousTime: TimeInterval?

    mutating func receive(_ contacts: [TransformContact], at time: TimeInterval,
                          angularVelocity: Double) -> PositionPathFeatures? {
        guard contacts.count == 2, time.isFinite else { return nil }
        let dt = previousTime.map { time - $0 }
        if let dt, dt <= 0 { return nil }
        guard let dt, dt <= 0.05 else {
            filtered = contacts.map(\.positionMM)
            samples = [Sample(time: time, points: filtered)]
            previousTime = time
            return nil
        }
        previousTime = time
        let blend = 1 - exp(-dt / 0.016)
        for index in 0..<2 {
            filtered[index].x += (contacts[index].positionMM.x - filtered[index].x) * blend
            filtered[index].y += (contacts[index].positionMM.y - filtered[index].y) * blend
        }
        let current = Sample(time: time, points: filtered)
        samples.removeAll { time - $0.time > 0.12 }
        if let last = samples.last {
            if distance(last.relative, current.relative) >= 0.75 ||
                zip(last.points, current.points).contains(where: { distance($0.0, $0.1) >= 0.75 }) {
                samples.append(current)
            }
        } else { samples.append(current) }
        let window = samples.last?.time == time ? samples : samples + [current]
        let relative = geometry(window.map(\.relative))
        let contactCurvatures = (0..<2).map { index in geometry(window.map { $0.points[index] }).curvature }
        let span = hypot(current.relative.x, current.relative.y)
        let agrees = (relative.bend ?? 0) * angularVelocity > 0
        let support = agrees ? min(1, abs(relative.curvature ?? 0) * span / 0.5) *
            min(1, abs(relative.bend ?? 0) / 0.12) : 0
        return PositionPathFeatures(relativeCurvature: relative.curvature, contactCurvatures: contactCurvatures,
            relativeBend: relative.bend, relativeTravel: relative.travel, rotationSupport: support)
    }

    private func geometry(_ points: [CGPoint]) -> (curvature: Double?, bend: Double?, travel: Double) {
        guard points.count >= 3 else { return (nil, nil, 0) }
        let lengths = zip(points, points.dropFirst()).map { distance($0.0, $0.1) }
        let travel = lengths.reduce(0, +)
        guard travel >= 3 else { return (nil, nil, travel) }
        var cumulative = 0.0
        var middle = 1
        for index in lengths.indices {
            cumulative += lengths[index]
            if cumulative >= travel / 2 { middle = min(points.count - 2, max(1, index + 1)); break }
        }
        let a = points[0], b = points[middle], c = points[points.count - 1]
        let u = CGPoint(x: b.x - a.x, y: b.y - a.y)
        let v = CGPoint(x: c.x - b.x, y: c.y - b.y)
        let first = hypot(u.x, u.y), second = hypot(v.x, v.y), chord = distance(a, c)
        guard first >= 0.75, second >= 0.75, chord >= 0.75 else { return (nil, nil, travel) }
        let cross = u.x * v.y - u.y * v.x
        return (2 * cross / (first * second * chord), atan2(cross, u.x * v.x + u.y * v.y), travel)
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }
}
