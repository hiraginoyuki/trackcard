import CoreGraphics
import Testing
@testable import TrackpadCore

private func pair(distance: Double = 40, angle: Double = 0, offset: CGPoint = .zero) -> [TransformContact] {
    [TransformContact(id: 1, positionMM: offset),
     TransformContact(id: 2, positionMM: CGPoint(x: offset.x + distance * cos(angle),
                                               y: offset.y + distance * sin(angle)))]
}

private func centeredPair(distance: Double = 40, angle: Double = 0,
                          center: CGPoint = CGPoint(x: 20, y: 0)) -> [TransformContact] {
    pair(distance: distance, angle: angle,
         offset: CGPoint(x: center.x - distance / 2 * cos(angle),
                         y: center.y - distance / 2 * sin(angle)))
}

// Keep geometry fixed through the ambiguity window; return the first action.
private func recognize(_ transform: inout ContactTransform, _ contacts: [TransformContact], canBegin: Bool = false) -> ContactTransformUpdate? {
    for _ in 0..<24 {
        if let update = transform.receive(contacts, canBegin: canBegin) { return update }
    }
    return nil
}

@Test func parallelTwoFingerMovementDoesNotResizeOrChangeOpacity() {
    var transform = ContactTransform()
    #expect(transform.receive(pair(), canBegin: true) == nil)
    #expect(transform.isTracking && !transform.isActive)
    #expect(transform.receive(pair(offset: CGPoint(x: 30, y: -15)), canBegin: false) == nil)
    #expect(transform.receive(pair(distance: 40.4, angle: .pi / 180), canBegin: false) == nil)
    #expect(!transform.isActive)
}

@Test func pinchIncludesRecognitionDistanceThenUsesIncrementalRatios() throws {
    var transform = ContactTransform()
    _ = transform.receive(pair(), canBegin: true)
    let beginResult = recognize(&transform, pair(distance: 44))
    let began = try #require(beginResult)
    #expect(began.kind == .magnify && began.phase == .began)
    #expect(abs(began.magnification - 0.1) < 0.000001)
    #expect(transform.isActive)
    let changeResult = transform.receive(pair(distance: 48.4), canBegin: false)
    let changed = try #require(changeResult)
    #expect(changed.phase == .changed)
    #expect(abs(changed.magnification - 0.1) < 0.000001)
    let endResult = transform.receive([], canBegin: false)
    let ended = try #require(endResult)
    #expect(ended.kind == .magnify && ended.phase == .ended)
    #expect(!transform.isTracking && !transform.isActive)
    #expect(transform.receive([], canBegin: false) == nil)
}

@Test func rotationChangesOpacityWithoutInterpretingTranslationAsPinch() throws {
    var transform = ContactTransform()
    _ = transform.receive(pair(), canBegin: true)
    let result = recognize(&transform, pair(angle: .pi / 12))
    let update = try #require(result)
    #expect(update.kind == .rotate && update.phase == .began)
    #expect(abs(update.rotation - .pi / 12) < 0.000001)
    let continuedResult = transform.receive(pair(distance: 45, angle: .pi / 10), canBegin: false)
    let continued = try #require(continuedResult)
    #expect(continued.kind == .rotate)
    #expect(abs(continued.rotation - .pi / 60) < 0.000001)
}

@Test func rotationCrossesTheAngleSeamWithoutJumping() throws {
    var transform = ContactTransform()
    _ = transform.receive(pair(angle: .pi * 178 / 180), canBegin: true)
    #expect(transform.receive(pair(angle: -.pi * 178 / 180), canBegin: false) == nil)
    let result = recognize(&transform, pair(angle: -.pi * 166 / 180))
    let update = try #require(result)
    #expect(update.kind == .rotate)
    #expect(abs(update.rotation - .pi * 16 / 180) < 0.000001)
}

@Test func smallAngularJitterCannotRecognizeOpacity() {
    var transform = ContactTransform()
    _ = transform.receive(pair(), canBegin: true)
    for _ in 0..<10 {
        for degrees in [0.4, -0.5, 0.8, -0.2, 0.1] {
            #expect(transform.receive(pair(angle: degrees * .pi / 180), canBegin: false) == nil)
        }
    }
    #expect(transform.isTracking && !transform.isActive)
}

@Test func aSwipeRemainsMovementDespiteLaterRotationOrPinchDrift() {
    for offset in [CGPoint(x: 5, y: 0), CGPoint(x: 0, y: 5), CGPoint(x: -5, y: -5)] {
        var transform = ContactTransform()
        _ = transform.receive(pair(), canBegin: true)
        #expect(transform.receive(pair(angle: .pi / 60, offset: offset), canBegin: false) == nil)
        #expect(transform.receive(pair(distance: 44, angle: .pi / 6, offset: offset), canBegin: false) == nil)
        #expect(transform.isTracking && !transform.isActive)
        _ = transform.receive([], canBegin: false)
        _ = transform.receive(pair(), canBegin: true)
        #expect(recognize(&transform, pair(angle: .pi / 12))?.kind == .rotate)
    }
}

@Test func aSingleFastTranslatedFrameCannotStealMovementAsRotation() {
    var transform = ContactTransform()
    _ = transform.receive(pair(), canBegin: true)
    #expect(transform.receive(pair(angle: .pi / 12, offset: CGPoint(x: 20, y: 0)), canBegin: false) == nil)
    #expect(!transform.isActive)
}

@Test func closeContactsNeedPhysicalRotationTravelBeyondAngleNoise() {
    var transform = ContactTransform()
    _ = transform.receive(pair(distance: 8), canBegin: true)
    #expect(transform.receive(pair(distance: 8, angle: .pi / 12), canBegin: false) == nil)
    #expect(!transform.isActive)
}

@Test func aPairStartingOutsideCannotTakeOverMidGesture() {
    var transform = ContactTransform()
    _ = transform.receive(pair(), canBegin: false)
    #expect(!transform.isTracking)
    #expect(transform.receive(pair(distance: 60), canBegin: true) == nil)
    _ = transform.receive([], canBegin: false)
    _ = transform.receive(pair(), canBegin: true)
    #expect(recognize(&transform, pair(distance: 60), canBegin: true)?.kind == .magnify)
}

@Test func replacingAContactEndsOnceAndRequiresANewPair() {
    var transform = ContactTransform()
    _ = transform.receive(pair(), canBegin: true)
    _ = recognize(&transform, pair(distance: 44))
    let changedIdentity = [TransformContact(id: 1, positionMM: .zero),
                           TransformContact(id: 3, positionMM: CGPoint(x: 60, y: 0))]
    #expect(transform.receive(changedIdentity, canBegin: true)?.phase == .ended)
    #expect(!transform.isTracking && !transform.isActive)
    #expect(transform.receive(changedIdentity, canBegin: true) == nil)
    _ = transform.receive([], canBegin: false)
    _ = transform.receive(changedIdentity, canBegin: true)
    #expect(transform.isTracking)
}

@Test func thirdFingerEndsTransformForSystemGestures() {
    var transform = ContactTransform()
    _ = transform.receive(pair(), canBegin: true)
    _ = recognize(&transform, pair(distance: 44))
    let three = pair() + [TransformContact(id: 3, positionMM: CGPoint(x: 20, y: 20))]
    #expect(transform.receive(three, canBegin: true)?.phase == .ended)
    #expect(!transform.isTracking && !transform.isActive)
}

@Test func malformedOrCoincidentContactsCannotProduceATransform() {
    var transform = ContactTransform()
    let sameID = [TransformContact(id: 1, positionMM: .zero),
                  TransformContact(id: 1, positionMM: CGPoint(x: 40, y: 0))]
    #expect(transform.receive(sameID, canBegin: true) == nil)
    #expect(!transform.isTracking)
    _ = transform.receive(pair(distance: 0), canBegin: true)
    #expect(!transform.isTracking)
    #expect(transform.receive(pair(distance: 40), canBegin: true) == nil)
    _ = transform.receive([], canBegin: false)
    let invalid = [TransformContact(id: 1, positionMM: .zero),
                   TransformContact(id: 2, positionMM: CGPoint(x: CGFloat.infinity, y: 0))]
    #expect(transform.receive(invalid, canBegin: true) == nil)
    #expect(!transform.isTracking)
}

@Test func briefSpacingEvidenceDoesNotLockPinchBeforeTheTurnDevelops() throws {
    var transform = ContactTransform()
    _ = transform.receive(pair(), canBegin: true, at: 0)
    func centered(_ angle: Double) -> [TransformContact] {
        pair(distance: 43.3, angle: angle, offset: CGPoint(x: 20 - 43.3 / 2 * cos(angle), y: -43.3 / 2 * sin(angle)))
    }
    #expect(transform.receive(centered(0), canBegin: false, at: 0.01) == nil)
    #expect(transform.receive(centered(.pi / 90), canBegin: false, at: 0.04) == nil)
    #expect(transform.receive(centered(.pi / 45), canBegin: false, at: 0.08)?.kind == .rotate)
    let result = transform.receive(centered(.pi / 30), canBegin: false, at: 0.12)
    let update = try #require(result)
    #expect(update.kind == .rotate && transform.intent == .rotation)
}

@Test func clearPinchRecognizesEarlyInEitherDirectionAndPreservesInitialTravel() throws {
    for distance in [37.5, 42.5] {
        var transform = ContactTransform()
        _ = transform.receive(centeredPair(), canBegin: true, at: 0)
        #expect(transform.receive(centeredPair(distance: distance), canBegin: false, at: 0.01) == nil)
        #expect(transform.receive(centeredPair(distance: distance), canBegin: false, at: 0.03) == nil)
        let result = transform.receive(centeredPair(distance: distance), canBegin: false, at: 0.043)
        let began = try #require(result)
        #expect(began.kind == .magnify && began.phase == .began)
        #expect(abs(began.magnification - (distance / 40 - 1)) < 1e-9)
        #expect(transform.intent == .pinch)
        #expect(transform.receive([], canBegin: false, at: 0.05)?.phase == .ended)
    }
}

@Test func clearPinchLatencyIsBoundedAtCommonSamplingRates() {
    for rate in [60.0, 120.0] {
        var transform = ContactTransform()
        _ = transform.receive(centeredPair(), canBegin: true, at: 0)
        var beganAt: Double?
        for sample in 1...8 {
            let time = Double(sample) / rate
            if transform.receive(centeredPair(distance: 43), canBegin: false, at: time)?.phase == .began {
                beganAt = time
                break
            }
        }
        #expect(beganAt != nil)
        #expect((beganAt ?? 1) <= 0.032 + 2 / rate)
    }
}

@Test func mixedPinchEvidenceStillWaitsForTheAmbiguityWindow() {
    var transform = ContactTransform()
    _ = transform.receive(centeredPair(), canBegin: true, at: 0)
    let mixed = centeredPair(distance: 44, angle: 1.5 * .pi / 180)
    for time in [0.01, 0.04, 0.07, 0.10] {
        #expect(transform.receive(mixed, canBegin: false, at: time) == nil)
    }
    #expect(transform.receive(mixed, canBegin: false, at: 0.11)?.kind == .magnify)
}

@Test func sharedMovementCannotUseTheEarlyPinchPath() {
    var transform = ContactTransform()
    _ = transform.receive(centeredPair(), canBegin: true, at: 0)
    let translated = centeredPair(distance: 42.5, center: CGPoint(x: 22, y: 0))
    for time in [0.01, 0.04, 0.07, 0.12] {
        #expect(transform.receive(translated, canBegin: false, at: time) == nil)
    }
    #expect(transform.intent == .undecided)
}

@Test func earlyPinchConfidenceMustBeContinuousAndKeepItsDirection() {
    for interruption in [centeredPair(distance: 42.5, angle: 1.5 * .pi / 180),
                         centeredPair(distance: 40.5), centeredPair(distance: 37.5)] {
        var transform = ContactTransform()
        _ = transform.receive(centeredPair(), canBegin: true, at: 0)
        #expect(transform.receive(centeredPair(distance: 42.5), canBegin: false, at: 0.01) == nil)
        #expect(transform.receive(interruption, canBegin: false, at: 0.03) == nil)
        #expect(transform.receive(centeredPair(distance: 42.5), canBegin: false, at: 0.04) == nil)
        #expect(transform.receive(centeredPair(distance: 42.5), canBegin: false, at: 0.06) == nil)
        #expect(transform.receive(centeredPair(distance: 42.5), canBegin: false, at: 0.073)?.kind == .magnify)
    }
}

@Test func earlyPinchUsesHardwareTimeForBatchedCallbacks() {
    var transform = ContactTransform()
    _ = transform.receive(centeredPair(), canBegin: true, at: 10, sourceTimestamp: 100)
    #expect(transform.receive(centeredPair(distance: 42.5), canBegin: false,
                              at: 10.000001, sourceTimestamp: 100.01) == nil)
    #expect(transform.receive(centeredPair(distance: 42.5), canBegin: false,
                              at: 10.000002, sourceTimestamp: 100.03) == nil)
    #expect(transform.receive(centeredPair(distance: 42.5), canBegin: false,
                              at: 10.000003, sourceTimestamp: 100.043)?.kind == .magnify)
}

@Test func provisionalEvidenceStrengthensForClearMotionAndWeakensForAmbiguity() {
    var transform = ContactTransform()
    _ = transform.receive(centeredPair(), canBegin: true, at: 0)
    #expect(transform.assessment.confidence == 0 && transform.assessment.scaleRatio == 1)
    #expect(transform.receive(centeredPair(distance: 42), canBegin: false, at: 0.01) == nil)
    let clear = transform.assessment
    #expect(clear.leadingIntent == .pinch && clear.confidence > 0.7)
    #expect(abs(clear.scaleRatio - 1.05) < 1e-9 && !transform.isActive)
    #expect(transform.receive(centeredPair(distance: 42, angle: .pi / 90), canBegin: false, at: 0.02) == nil)
    #expect(transform.assessment.confidence < clear.confidence / 2)
    _ = transform.receive([], canBegin: false, at: 0.03)
    #expect(transform.assessment.confidence == 0 && transform.assessment.scaleRatio == 1)
}

@Test func interruptedOwnershipCannotRestartUntilRelease() {
    var transform = ContactTransform()
    _ = transform.receive(centeredPair(), canBegin: true, at: 0)
    _ = transform.receive(centeredPair(distance: 43), canBegin: false, at: 0.01)
    _ = transform.receive(centeredPair(distance: 43), canBegin: false, at: 0.043)
    #expect(transform.interrupt()?.phase == .ended)
    #expect(transform.interrupt() == nil)
    #expect(!transform.isTracking && transform.assessment.confidence == 0)
    #expect(transform.receive(centeredPair(distance: 44), canBegin: true, at: 0.05) == nil)
    #expect(!transform.isTracking)
    _ = transform.receive([], canBegin: false, at: 0.06)
    _ = transform.receive(centeredPair(), canBegin: true, at: 0.07)
    #expect(transform.isTracking && transform.intent == .undecided)
}

@Test func bluetoothBatchTimingUsesSourceIntervalsForAmbiguity() {
    var transform = ContactTransform()
    _ = transform.receive(pair(), canBegin: true, at: 10, sourceTimestamp: 100)
    var result: ContactTransformUpdate?
    for index in 1...9 {
        result = transform.receive(pair(distance: 44), canBegin: false,
            at: 10 + Double(index) * 0.000003, sourceTimestamp: 100 + Double(index) * 0.015)
        if result != nil { break }
    }
    #expect(result?.kind == .magnify)
}

@Test func aStaleStreamEndsAndCannotResumeWithoutRelease() {
    var transform = ContactTransform()
    _ = transform.receive(pair(), canBegin: true, at: 0)
    _ = transform.receive(pair(distance: 44), canBegin: false, at: 0.01)
    _ = transform.receive(pair(distance: 44), canBegin: false, at: 0.12)
    #expect(transform.isActive)
    #expect(transform.receive(pair(distance: 48), canBegin: false, at: 0.5)?.phase == .ended)
    #expect(!transform.isTracking)
    #expect(transform.receive(pair(distance: 50), canBegin: true, at: 0.51) == nil)
    _ = transform.receive([], canBegin: false, at: 0.52)
    _ = transform.receive(pair(), canBegin: true, at: 0.53)
    #expect(transform.isTracking)
}
