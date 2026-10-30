import Foundation

/// Critically damped opacity follows a moving target. Retargeting preserves
/// the displayed value and velocity, including when the target reverses.
public struct OpacityMotion: Sendable {
    private var motion: ResizeMotion
    public var value: Double { min(1, max(0, motion.scale - 1)) }
    public var velocity: Double { motion.velocity }
    public init(value: Double) { motion = ResizeMotion(scale: 1 + Self.clamped(value)) }
    public mutating func reset(to value: Double, at time: TimeInterval? = nil) {
        guard value.isFinite else { return }
        motion.reset(to: 1 + Self.clamped(value), at: time)
    }
    public mutating func retarget(to value: Double) {
        guard value.isFinite else { return }
        motion.retarget(to: 1 + Self.clamped(value))
    }
    public mutating func advance(at time: TimeInterval, reduceMotion: Bool = false, maximum: Double = 1) {
        guard maximum.isFinite else { return }
        motion.advance(at: time, reduceMotion: reduceMotion, settlingTime: 0.09)
        let ceiling = Self.clamped(maximum)
        if value > ceiling { motion.reset(to: 1 + ceiling, at: time) }
    }
    private static func clamped(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }
}
