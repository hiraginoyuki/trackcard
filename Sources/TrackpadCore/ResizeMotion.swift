import Foundation

/// A short, critically damped spring bridges uneven contact samples. Retargeting
/// preserves velocity; display ticks move both trackpads together without bounce.
public struct ResizeMotion: Sendable {
    public private(set) var scale: Double
    public private(set) var target: Double
    public private(set) var velocity: Double = 0
    private var previousTime: TimeInterval?

    public init(scale: Double) {
        self.scale = scale
        target = scale
    }

    public mutating func reset(to scale: Double, at time: TimeInterval? = nil) {
        guard scale.isFinite, scale > 0 else { return }
        self.scale = scale
        target = scale
        velocity = 0
        previousTime = time
    }

    public mutating func retarget(to scale: Double) {
        guard scale.isFinite, scale > 0 else { return }
        target = scale
    }

    public mutating func advance(at time: TimeInterval, reduceMotion: Bool = false, settlingTime: TimeInterval = 0.05) {
        guard time.isFinite, settlingTime.isFinite, settlingTime > 0 else { return }
        let dt = previousTime.map { time - $0 } ?? 1 / 120
        guard dt > 0 else { return }
        previousTime = time
        guard !reduceMotion, dt < 0.1 else {
            scale = target
            velocity = 0
            return
        }
        // Solve the spring analytically so its response is the same at every
        // refresh rate. This is tighter than the corner-docking spring: about
        // 90% of a size change arrives in 50 ms, with a short settling tail.
        let frequency = 4 / settlingTime
        let displacement = scale - target
        let coefficient = velocity + frequency * displacement
        let decay = exp(-frequency * dt)
        scale = target + (displacement + coefficient * dt) * decay
        velocity = (velocity - frequency * coefficient * dt) * decay
        if (displacement < 0 && scale >= target) || (displacement > 0 && scale <= target)
            || (abs(target - scale) < 0.00001 && abs(velocity) < 0.001) {
            scale = target
            velocity = 0
        }
    }
}
