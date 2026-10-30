import Foundation

/// Percentage crossings without quantizing the rendered value. A sample that
/// crosses several marks emits only the strongest feedback, with landmarks
/// taking priority over the rate limit for ordinary one-point steps.
public struct AdjustmentDetents: Sendable {
    public enum Strength: Int, Sendable { case tiny, medium, strong }

    private let range: ClosedRange<Double>
    private var previous: Double?
    private var muted: Set<Int> = []
    private var lastPulse: TimeInterval = -.infinity

    public init(range: ClosedRange<Double> = 0.25...1.5) { self.range = range }

    public mutating func reset(to value: Double) {
        previous = valid(value) ? value : nil
        muted = []
        if let previous {
            let percentage = Int((previous * 100).rounded())
            if abs(previous - Double(percentage) / 100) < 1e-9 { muted.insert(percentage) }
        }
        lastPulse = -.infinity
    }

    public mutating func update(_ value: Double, at time: TimeInterval) -> Strength? {
        guard valid(value), time.isFinite else { return nil }
        guard let previous else { reset(to: value); return nil }
        self.previous = value
        // Re-arm a mark only after moving 0.2 percentage points away. Use the
        // preceding position so leaving the mark cannot itself retrigger it.
        muted = muted.filter { abs(previous - Double($0) / 100) < 0.002 - 1e-9 }
        let lower = min(previous, value) * 100
        let upper = max(previous, value) * 100
        let first = Int(ceil(lower - 1e-9))
        let last = Int(floor(upper + 1e-9))
        guard first <= last else { return nil }
        var strongest: Strength?
        for percentage in first...last {
            let mark = Double(percentage) / 100
            let crossed = value > previous ? previous < mark && value >= mark - 1e-9 :
                value < previous && previous > mark && value <= mark + 1e-9
            guard crossed, muted.insert(percentage).inserted else { continue }
            let strength: Strength = percentage == 50 || percentage == 100 ||
                abs(mark - range.lowerBound) < 1e-9 ? .strong :
                percentage.isMultiple(of: 10) ? .medium : .tiny
            if strongest == nil || strength.rawValue > strongest!.rawValue { strongest = strength }
        }
        guard let strongest else { return nil }
        // Higher-priority marks must not disappear behind a preceding tiny
        // tick. Coalesce only tiny ticks during very fast movement.
        guard strongest != .tiny || time - lastPulse >= 0.02 else { return nil }
        lastPulse = time
        return strongest
    }

    private func valid(_ value: Double) -> Bool {
        value.isFinite && range.contains(value) && (0...1.5).contains(value)
    }
}
