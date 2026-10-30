import Testing
@testable import TrackpadCore

@Test func adjustmentDetentsUseTinyMediumAndStrongPercentageMarks() {
    var detents = AdjustmentDetents()
    detents.reset(to: 0.47)
    for (index, value) in [0.48, 0.49, 0.5, 0.51, 0.59, 0.6, 0.61, 0.99, 1.0, 1.01].enumerated() {
        let expected: AdjustmentDetents.Strength = value == 0.5 || value == 1 ? .strong :
            value == 0.6 || value == 0.99 ? .medium : .tiny
        #expect(detents.update(value, at: Double(index) / 10) == expected)
    }
}

@Test func strongestCrossedMarkWinsWhenInputSkipsPercentages() {
    var detents = AdjustmentDetents()
    detents.reset(to: 0.47)
    #expect(detents.update(0.62, at: 0) == .strong)
    #expect(detents.update(0.83, at: 0.1) == .medium)
    #expect(detents.update(1.04, at: 0.2) == .strong)
    #expect(detents.update(0.95, at: 0.3) == .strong)
    #expect(detents.update(0.76, at: 0.4) == .medium)
}

@Test func minimumIsStrongForEachControlAndDoesNotRepeatWhileClamped() {
    for minimum in [0.15, 0.25] {
        var detents = AdjustmentDetents(range: minimum...1.5)
        detents.reset(to: minimum + 0.02)
        #expect(detents.update(minimum, at: 0) == .strong)
        #expect(detents.update(minimum, at: 0.1) == nil)
        #expect(detents.update(minimum + 0.001, at: 0.2) == nil)
        #expect(detents.update(minimum, at: 0.3) == nil)
    }
}

@Test func restingNoiseIsMutedUntilTheMarkIsLeftAndCrossedAgain() {
    var detents = AdjustmentDetents()
    detents.reset(to: 0.5)
    for (index, value) in [0.499, 0.501, 0.5, 0.5015, 0.499].enumerated() {
        #expect(detents.update(value, at: Double(index) / 10) == nil)
    }
    #expect(detents.update(0.496, at: 0.6) == nil)
    #expect(detents.update(0.5, at: 0.7) == .strong)
    #expect(detents.update(0.501, at: 0.8) == nil)
    #expect(detents.update(0.499, at: 0.9) == nil)
}

@Test func descendingPercentagesUseTheSameHapticHierarchy() {
    var detents = AdjustmentDetents()
    detents.reset(to: 1.02)
    #expect(detents.update(1.01, at: 0) == .tiny)
    #expect(detents.update(1, at: 0.1) == .strong)
    #expect(detents.update(0.99, at: 0.2) == .tiny)
    #expect(detents.update(0.9, at: 0.3) == .medium)
    #expect(detents.update(0.5, at: 0.4) == .strong)
    #expect(detents.update(0.4, at: 0.5) == .medium)
    #expect(detents.update(0.25, at: 0.6) == .strong)
}

@Test func landmarksBypassTinyTickRateLimitAndSuppressedTicksDoNotReplay() {
    var detents = AdjustmentDetents()
    detents.reset(to: 0.47)
    #expect(detents.update(0.48, at: 0) == .tiny)
    #expect(detents.update(0.49, at: 0.005) == nil)
    #expect(detents.update(0.5, at: 0.01) == .strong)
    #expect(detents.update(0.6, at: 0.015) == .medium)
    #expect(detents.update(0.61, at: 0.02) == nil)
    #expect(detents.update(0.61, at: 0.1) == nil)
    #expect(detents.update(0.62, at: 0.11) == .tiny)
}

@Test func invalidDetentInputsDoNotCreateHaptics() {
    var detents = AdjustmentDetents()
    let initial = detents.update(0.5, at: 0)
    let invalidValue = detents.update(.nan, at: 0.1)
    let invalidTime = detents.update(0.6, at: .infinity)
    let excessiveValue = detents.update(.greatestFiniteMagnitude, at: 0.2)
    #expect(initial == nil && invalidValue == nil && invalidTime == nil && excessiveValue == nil)
}
