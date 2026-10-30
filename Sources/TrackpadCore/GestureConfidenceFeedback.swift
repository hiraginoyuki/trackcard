import Foundation

/// Smooth confidence in both directions, then express it through pulse cadence
/// and the available trackpad patterns. Only used before a decision commits.
public struct GestureConfidenceFeedback: Sendable {
    public private(set) var confidence: Double = 0
    private var lastTime: TimeInterval?
    private var lastPulse: TimeInterval = -.infinity

    public init() {}

    public mutating func update(_ target: Double, at time: TimeInterval) -> AdjustmentDetents.Strength? {
        guard target.isFinite, time.isFinite,
              lastTime.map({ time > $0 }) ?? true else { return nil }
        let dt = min(0.1, lastTime.map { time - $0 } ?? 1 / 120)
        lastTime = time
        confidence += (min(1, max(0, target)) - confidence) * (1 - exp(-dt / 0.035))
        guard confidence >= 0.05 else { return nil }
        let interval = 0.08 - 0.05 * confidence
        guard time - lastPulse >= interval else { return nil }
        lastPulse = time
        return confidence >= 0.8 ? .medium : .tiny
    }
}
