import CoreGraphics
import Testing
@testable import TrackpadCore

private func comparisonPair(_ distance: Double = 40, angle: Double = 0) -> [TransformContact] {
    [TransformContact(id: 1, positionMM: CGPoint(x: -distance / 2 * cos(angle), y: -distance / 2 * sin(angle))),
     TransformContact(id: 2, positionMM: CGPoint(x: distance / 2 * cos(angle), y: distance / 2 * sin(angle)))]
}

@Test func comparisonVariantsContainOneCurrentAndTheFullThresholdTimingCross() {
    let variants = ClassifierVariant.comparisons
    #expect(variants.count == 16 && variants.filter(\.isCurrent).count == 1)
    #expect(variants.first { $0.isCurrent }?.id == "source-clock-timers")
    #expect(variants.filter { !$0.isCurrent }.allSatisfy { $0.configuration.timingPolicy == .legacyRelative })
    #expect(variants.first { $0.isCurrent }?.configuration.timingPolicy == .sourceClock)
    #expect(variants.filter { !["relative-motion", "position-paths", "early-intent", "independent", "motion-boundary", "relative-turn", "source-clock-timers"].contains($0.id) }.allSatisfy { !$0.configuration.usesRelativeMotion })
    #expect(variants.filter { !["early-intent", "independent", "motion-boundary", "relative-turn", "source-clock-timers"].contains($0.id) }.allSatisfy { !$0.configuration.usesEarlyIntent })
    #expect(variants.filter { !["independent", "motion-boundary", "relative-turn", "source-clock-timers"].contains($0.id) }.allSatisfy { !$0.configuration.usesIndependentClassifiers })
    #expect(variants.first { $0.id == "independent" }?.configuration.usesMotionBoundary == false)
    #expect(variants.first { $0.id == "motion-boundary" }?.configuration.usesRelativeTurn == false)
    #expect(Set(variants.map(\.id)).count == variants.count)
    #expect(variants.first?.configuration.earlyPinchRatio == nil)
    for ratio in [0.04, 0.06, 0.08] {
        for duration in [0.016, 0.032] {
            #expect(variants.contains { $0.configuration.earlyPinchRatio == ratio && $0.configuration.earlyPinchDuration == duration })
        }
    }
}

@Test func comparisonShowsRealTimingDifferencesAndKeepsTheLastGesture() {
    var comparison = ClassifierComparison()
    comparison.receive(comparisonPair(), at: 0)
    comparison.receive(comparisonPair(42), at: 0.01)
    comparison.receive(comparisonPair(42), at: 0.027)
    #expect(comparison.traces.first { $0.variant.id == "4-16" }?.decision == .pinch)
    #expect(comparison.traces.first { $0.variant.isCurrent }?.decision == .undecided)
    comparison.receive(comparisonPair(43), at: 0.04)
    comparison.receive(comparisonPair(43), at: 0.073)
    #expect(abs((comparison.traces.first { $0.variant.isCurrent }?.decisionTime ?? 0) - 0.073) < 1e-9)
    #expect(comparison.traces.first?.decision == .undecided)
    let count = comparison.traces[0].samples.count
    comparison.receive([], at: 0.1)
    #expect(!comparison.isCollecting && comparison.traces[0].samples.count == count)
    comparison.receive(comparisonPair(), at: 0.2)
    #expect(comparison.isCollecting && comparison.traces.allSatisfy { $0.samples.count == 1 && $0.decisionTime == nil })
}

@Test func configurationSurvivesReleaseAndInterruptions() {
    let config = ContactTransform.Configuration(earlyPinchRatio: nil)
    var transform = ContactTransform(configuration: config)
    _ = transform.receive(comparisonPair(), canBegin: true, at: 0)
    _ = transform.receive([], canBegin: false, at: 0.01)
    #expect(transform.configuration == config)
    _ = transform.receive(comparisonPair(), canBegin: true, at: 0.02)
    _ = transform.receive(comparisonPair(44), canBegin: false, at: 0.03)
    #expect(transform.receive(comparisonPair(44), canBegin: false, at: 0.064) == nil)
}

@Test func comparisonScoresKeepChangingAfterCommitmentWithoutReclassifying() {
    var transform = ContactTransform(configuration: .init(usesIndependentClassifiers: false))
    _ = transform.receive(comparisonPair(), canBegin: true, at: 0)
    _ = transform.receive(comparisonPair(44), canBegin: true, at: 0.01)
    _ = transform.receive(comparisonPair(44), canBegin: true, at: 0.043)
    #expect(transform.intent == .pinch)
    let before = transform.assessment.scores.pinch
    _ = transform.receive(comparisonPair(44, angle: .pi / 9), canBegin: true, at: 0.06)
    #expect(transform.intent == .pinch && transform.assessment.scores.pinch < before)
    #expect(transform.assessment.scores.rotation > transform.assessment.scores.pinch)
}

@Test func comparisonUsesSourceTimeAndRejectsDuplicateFrames() {
    var comparison = ClassifierComparison()
    comparison.receive(comparisonPair(), at: 10, sourceTimestamp: 100)
    comparison.receive(comparisonPair(44), at: 10.000001, sourceTimestamp: 100.01)
    comparison.receive(comparisonPair(44), at: 10.000002, sourceTimestamp: 100.05)
    let trace = comparison.traces.first { $0.variant.isCurrent }!
    #expect(abs((trace.decisionTime ?? 0) - 0.05) < 1e-8)
    let revision = comparison.revision
    comparison.receive(comparisonPair(44), at: 10.000002, sourceTimestamp: 100.06)
    #expect(comparison.revision == revision)
}

@Test func staleComparisonWaitsForReleaseAndResetClearsEveryVariant() {
    var comparison = ClassifierComparison()
    comparison.receive(comparisonPair(), at: 0)
    comparison.receive(comparisonPair(44), at: 0.5)
    #expect(!comparison.isCollecting)
    comparison.receive(comparisonPair(44), at: 0.51)
    #expect(!comparison.isCollecting)
    comparison.receive([], at: 0.52)
    comparison.receive(comparisonPair(), at: 0.53)
    #expect(comparison.isCollecting)
    comparison.reset()
    #expect(comparison.traces.allSatisfy { $0.samples.isEmpty && $0.decisionTime == nil })
}

@Test func longerResizeTransitionRemainsContinuousAndHonorsReduceMotion() {
    var motion = ResizeMotion(scale: 0.5)
    motion.reset(to: 0.5, at: 0); motion.retarget(to: 0.8)
    for frame in 1...6 { motion.advance(at: Double(frame) / 120, settlingTime: 0.2) }
    #expect(motion.scale > 0.5 && motion.scale < 0.65)
    for frame in 7...24 { motion.advance(at: Double(frame) / 120, settlingTime: 0.2) }
    #expect(motion.scale > 0.77 && motion.scale < 0.8)
    motion.advance(at: 0.21, reduceMotion: true, settlingTime: 0.2)
    #expect(motion.scale == 0.8)
}

@Test func rightClickImmediatelyVetoesEveryComparisonAndWaitsForRelease() {
    var comparison = ClassifierComparison()
    comparison.receive(comparisonPair(), at: 0)
    comparison.receive(comparisonPair(42), at: 0.01)
    comparison.receiveRightClick()
    #expect(!comparison.isCollecting && comparison.traces.allSatisfy { $0.rightClickTime != nil })
    let count = comparison.traces[0].samples.count
    comparison.receive(comparisonPair(48), at: 0.05)
    #expect(comparison.traces[0].samples.count == count && comparison.traces.allSatisfy { $0.decisionTime == nil })
    comparison.receive([], at: 0.06)
    comparison.receive(comparisonPair(), at: 0.07)
    #expect(comparison.isCollecting && comparison.traces.allSatisfy { $0.rightClickTime == nil })
}
