import CoreGraphics
import Foundation
import Testing
@testable import TrackpadCore

private func earlyPair(offset: CGPoint = .zero, span: Double = 40,
                       forces: [Double?] = [nil, nil], uneven: Bool = false) -> [TransformContact] {
    [TransformContact(id: 1, positionMM: CGPoint(x: offset.x - span / 2, y: offset.y), force: forces[0]),
     TransformContact(id: 2, positionMM: CGPoint(x: offset.x + span / 2 + (uneven ? 1.5 : 0), y: offset.y), force: forces[1])]
}

@Test func coherentSwipeCanCommitOnTheFirstClearSubmillimetreSample() {
    for angle in [0.0, .pi / 2, .pi, -.pi / 2, .pi / 4] {
        var current = ContactTransform()
        var previous = ContactTransform(configuration: .init(usesEarlyIntent: false))
        for motion in [false, true] {
            let offset = motion ? CGPoint(x: 0.9 * cos(angle), y: 0.9 * sin(angle)) : .zero
            _ = current.receive(earlyPair(offset: offset), canBegin: true, at: motion ? 0.008 : 0)
            _ = previous.receive(earlyPair(offset: offset), canBegin: true, at: motion ? 0.008 : 0)
        }
        #expect(current.intent == .movement && previous.intent == .undecided)
        #expect(current.assessment.leadingIntent == .movement && current.assessment.confidence > 0.9)
    }
}

@Test func asymmetricFingerLandingAndSlowDriftDoNotTakeTheEarlySwipePath() {
    var asymmetric = ContactTransform(), slow = ContactTransform()
    _ = asymmetric.receive(earlyPair(), canBegin: true, at: 0)
    _ = asymmetric.receive(earlyPair(uneven: true), canBegin: true, at: 0.008)
    #expect(asymmetric.intent == .undecided)
    for index in 0...8 {
        _ = slow.receive(earlyPair(offset: CGPoint(x: Double(index) / 10, y: 0)),
                         canBegin: true, at: Double(index) / 100)
    }
    #expect(slow.intent == .undecided)
}

@Test func earlySwipeUsesHardwareTimeAndKeepsItsDecisionThroughAngularDrift() {
    var transform = ContactTransform()
    _ = transform.receive(earlyPair(), canBegin: true, at: 10, sourceTimestamp: 100)
    _ = transform.receive(earlyPair(offset: CGPoint(x: 0.9, y: 0)), canBegin: false,
                          at: 10.000001, sourceTimestamp: 100.008)
    #expect(transform.intent == .movement && abs(transform.elapsed - 0.008) < 1e-8)
    _ = transform.receive(earlyPair(offset: CGPoint(x: 2, y: 0), span: 48), canBegin: false,
                          at: 10.000002, sourceTimestamp: 100.016)
    #expect(transform.intent == .movement && !transform.isActive)
}

@Test func earlyPressCueDoesNotConfirmOrVetoAGesture() {
    var transform = ContactTransform()
    _ = transform.receive(earlyPair(forces: [20, 20]), canBegin: true, at: 0)
    _ = transform.receive(earlyPair(forces: [25, 80]), canBegin: false, at: 0.008)
    #expect(transform.isPressCandidate && transform.intent == .undecided && transform.isTracking)
    _ = transform.receive(earlyPair(offset: CGPoint(x: 0.9, y: 0), forces: [25, 80]), canBegin: false, at: 0.016)
    #expect(transform.intent == .movement && !transform.isPressCandidate)
}

@Test func pressCueReleasesAsSpacingDevelopsAndAllowsPinchRecognition() {
    var transform = ContactTransform()
    _ = transform.receive(earlyPair(forces: [20, 20]), canBegin: true, at: 0)
    _ = transform.receive(earlyPair(forces: [25, 140]), canBegin: false, at: 0.008)
    #expect(transform.isPressCandidate)
    _ = transform.receive(earlyPair(span: 42, forces: [25, 140]), canBegin: false, at: 0.016)
    #expect(!transform.isPressCandidate && transform.isTracking)
    for index in 3...10 {
        _ = transform.receive(earlyPair(span: 40 + Double(index) * 2, forces: [25, 140]),
                              canBegin: false, at: Double(index) * 0.008)
    }
    #expect(transform.intent == .pinch && !transform.isPressCandidate)
}

@Test func missingInvalidOrUnchangedPressureCannotCreateAPressCue() {
    for forces in [[Double?.none, nil], [Double?.some(.nan), 100], [.infinity, 100], [-1, 100], [100, 100]] {
        var transform = ContactTransform()
        _ = transform.receive(earlyPair(forces: forces), canBegin: true, at: 0)
        _ = transform.receive(earlyPair(forces: forces), canBegin: false, at: 0.008)
        #expect(!transform.isPressCandidate && transform.assessment.pressScore.isFinite)
    }
}

@Test func smallPressureNoiseDoesNotFlashTheProvisionalFeedbackBackOn() {
    var transform = ContactTransform()
    _ = transform.receive(earlyPair(forces: [20, 20]), canBegin: true, at: 0)
    _ = transform.receive(earlyPair(forces: [25, 80]), canBegin: false, at: 0.008)
    _ = transform.receive(earlyPair(forces: [25, 69]), canBegin: false, at: 0.016)
    #expect(transform.isPressCandidate)
    _ = transform.receive(earlyPair(forces: [25, 40]), canBegin: false, at: 0.024)
    #expect(!transform.isPressCandidate && transform.isTracking)
}

@Test func anActualRightClickStillVetoesAPressCueUntilRelease() {
    var transform = ContactTransform()
    _ = transform.receive(earlyPair(forces: [20, 20]), canBegin: true, at: 0)
    _ = transform.receive(earlyPair(forces: [25, 80]), canBegin: false, at: 0.008)
    _ = transform.interrupt()
    _ = transform.receive(earlyPair(span: 60, forces: [25, 80]), canBegin: true, at: 0.016)
    #expect(!transform.isTracking && !transform.isPressCandidate && transform.intent == .undecided)
    _ = transform.receive([], canBegin: false, at: 0.024)
    _ = transform.receive(earlyPair(), canBegin: true, at: 0.032)
    #expect(transform.isTracking)
}

@Test func comparisonRetainsTheEarlyPressCueSeparatelyFromTheFinalDecision() {
    var comparison = ClassifierComparison()
    comparison.receive(earlyPair(forces: [20, 20]), at: 0)
    comparison.receive(earlyPair(forces: [25, 80]), at: 0.008)
    var current = comparison.traces.first { $0.variant.isCurrent }!
    #expect(current.pressCueTime == 0.008 && current.decisionTime == nil && current.rightClickTime == nil)
    #expect(comparison.traces.filter { !$0.variant.configuration.usesEarlyIntent }.allSatisfy { $0.pressCueTime == nil })
    comparison.receive(earlyPair(offset: CGPoint(x: 0.9, y: 0), forces: [25, 80]), at: 0.016)
    current = comparison.traces.first { $0.variant.isCurrent }!
    #expect(current.pressCueTime == 0.008 && current.decision == .movement && current.decisionTime == 0.016)
}

private func positionPointer(_ transform: inout ContactTransform) {
    _ = transform.receive([TransformContact(id: 1, positionMM: CGPoint(x: -22, y: 0))], canBegin: false, at: 0)
    _ = transform.receive([TransformContact(id: 1, positionMM: CGPoint(x: -20, y: 0))], canBegin: false, at: 0.008)
    _ = transform.receive(earlyPair(), canBegin: true, at: 0.016)
}

@Test func heldPointerFingerStronglyDiscountsTiltWithoutForcingSwipe() {
    var transform = ContactTransform()
    positionPointer(&transform)
    #expect(transform.heldPointerContactID == 1 && transform.assessment.tiltPrior == 0.05)
    let rotated = [TransformContact(id: 1, positionMM: CGPoint(x: -20, y: 0)),
                   TransformContact(id: 2, positionMM: CGPoint(x: -20 + 40 * cos(Double.pi / 30), y: 40 * sin(Double.pi / 30)))]
    for index in 1...20 {
        _ = transform.receive(rotated, canBegin: true, at: 0.016 + Double(index) * 0.008)
    }
    #expect(transform.intent == .undecided && transform.assessment.tiltPrior == 0.05)
}

@Test func rarePinchRemainsAvailableAfterPositioningThePointer() {
    var transform = ContactTransform()
    positionPointer(&transform)
    for index in 1...20 {
        _ = transform.receive(earlyPair(span: 44), canBegin: true, at: 0.016 + Double(index) * 0.008)
    }
    #expect(transform.intent == .pinch && transform.heldPointerContactID == 1)
}

@Test func aFullLiftClearsThePointerLandingPrior() {
    var transform = ContactTransform()
    positionPointer(&transform)
    _ = transform.receive([], canBegin: false, at: 0.024)
    _ = transform.receive(earlyPair(), canBegin: true, at: 0.032)
    #expect(transform.heldPointerContactID == nil && transform.assessment.tiltPrior == 1)
    let rotated = [TransformContact(id: 1, positionMM: CGPoint(x: -20, y: 0)),
                   TransformContact(id: 2, positionMM: CGPoint(x: -20 + 40 * cos(Double.pi / 30), y: 40 * sin(Double.pi / 30)))]
    for index in 1...20 {
        _ = transform.receive(rotated, canBegin: true, at: 0.032 + Double(index) * 0.008)
    }
    #expect(transform.intent == .rotation)
}

@Test func stationaryStaggeredLandingsDoNotReceiveThePointerPrior() {
    var transform = ContactTransform()
    for index in 0...5 {
        _ = transform.receive([TransformContact(id: 1, positionMM: CGPoint(x: -20, y: 0))],
                              canBegin: true, at: Double(index) * 0.008)
    }
    _ = transform.receive(earlyPair(), canBegin: true, at: 0.048)
    #expect(transform.heldPointerContactID == nil && transform.assessment.tiltPrior == 1)
}

@Test func staleOrReplacedPointerContactsCannotSupplyALandingPrior() {
    for replacement in [false, true] {
        var transform = ContactTransform()
        _ = transform.receive([TransformContact(id: 1, positionMM: CGPoint(x: -22, y: 0))], canBegin: false, at: 0)
        _ = transform.receive([TransformContact(id: 1, positionMM: CGPoint(x: -20, y: 0))], canBegin: false, at: 0.008)
        let contacts = replacement ? [TransformContact(id: 3, positionMM: CGPoint(x: -20, y: 0)),
                                      TransformContact(id: 2, positionMM: CGPoint(x: 20, y: 0))] : earlyPair()
        _ = transform.receive(contacts, canBegin: true, at: replacement ? 0.016 : 1)
        #expect(transform.heldPointerContactID == nil)
    }
}

@Test func pointerEntryAllowsThePriorBeforeLargePhysicalTravelAccumulates() {
    var transform = ContactTransform()
    _ = transform.receive([TransformContact(id: 1, positionMM: CGPoint(x: -20.6, y: 0))], canBegin: false, at: 0)
    _ = transform.receive([TransformContact(id: 1, positionMM: CGPoint(x: -20, y: 0))], canBegin: false, at: 0.008)
    _ = transform.receive(earlyPair(), canBegin: true, at: 0.016)
    #expect(transform.heldPointerContactID == 1 && transform.assessment.tiltPrior == 0.05)
}

@Test func singleFingerMovementAlreadyInsideTheTargetDoesNotPenalizeTilt() {
    var transform = ContactTransform()
    _ = transform.receive([TransformContact(id: 1, positionMM: CGPoint(x: -40, y: 0))], canBegin: true, at: 0)
    _ = transform.receive([TransformContact(id: 1, positionMM: CGPoint(x: -20, y: 0))], canBegin: true, at: 0.008)
    _ = transform.receive(earlyPair(), canBegin: true, at: 0.016)
    #expect(transform.heldPointerContactID == nil && transform.assessment.tiltPrior == 1)
}

@Test func comparisonUsesPointerContextWithoutRejectingOffTargetRecordings() {
    var comparison = ClassifierComparison()
    comparison.receive([TransformContact(id: 1, positionMM: CGPoint(x: -22, y: 0))], at: 0, pointerOverTarget: false)
    comparison.receive([TransformContact(id: 1, positionMM: CGPoint(x: -20, y: 0))], at: 0.008, pointerOverTarget: false)
    comparison.receive(earlyPair(), at: 0.016, pointerOverTarget: true)
    #expect(comparison.traces.first { $0.variant.isCurrent }?.samples.first?.tiltPrior == 0.05)
    #expect(comparison.traces.filter { !$0.variant.configuration.usesEarlyIntent }.allSatisfy { $0.samples.first?.tiltPrior == 1 })
}

@Test func recordingPointerContextIsOptionalAndRoundTrips() throws {
    let sample = RecordedContactFrame(deviceID: 1, sequence: 1, time: 0, contacts: [], pointerOverPreview: true)
    let data = try JSONEncoder().encode(sample)
    #expect(try JSONDecoder().decode(RecordedContactFrame.self, from: data).pointerOverPreview == true)
    var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    json.removeValue(forKey: "pointerOverPreview")
    let old = try JSONDecoder().decode(RecordedContactFrame.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(old.pointerOverPreview == nil)
}
