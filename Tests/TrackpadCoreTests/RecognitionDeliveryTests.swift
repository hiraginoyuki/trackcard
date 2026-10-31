import CoreGraphics
import Testing
@testable import TrackpadCore

private func deliver(_ delivery: inout RecognitionDelivery, id: UInt64 = 1, stream: UInt64 = 1,
                     sequence: UInt64, arrival: Double, source: Double? = nil, count: Int = 2,
                     drained: Double? = nil) -> RecognitionDelivery.Receipt {
    delivery.receive(deviceID: id, streamID: stream, sequence: sequence, receivedAt: arrival,
                     sourceTimestamp: source ?? (100 + arrival), touchingCount: count, drainedAt: drained ?? arrival)
}

private func deliveryPair(_ span: Double = 40, id: Int32 = 1) -> [TransformContact] {
    [TransformContact(id: id, positionMM: CGPoint(x: -span / 2, y: 0)),
     TransformContact(id: id + 1, positionMM: CGPoint(x: span / 2, y: 0))]
}

@Test func equalArrivalStampsKeepAdvancingSourceFramesAndTheirPhysicalTiming() {
    var delivery = RecognitionDelivery()
    var transform = ContactTransform()
    var previousTime = -Double.infinity
    for index in 0...2 {
        let source = 100 + Double(index) * 0.008
        let receipt = deliver(&delivery, sequence: UInt64(index + 1), arrival: 1, source: source, drained: 1.016)
        #expect(receipt.accepted && receipt.canRecognize && !receipt.interrupted)
        #expect(receipt.recognitionTime > previousTime)
        previousTime = receipt.recognitionTime
        _ = transform.receive(deliveryPair(40 + Double(index) * 6), canBegin: true,
            at: receipt.recognitionTime, sourceTimestamp: source)
    }
    #expect(transform.intent == .pinch && transform.committedClassifier == .decisiveRadialPinch)
    #expect(abs(transform.elapsed - 0.016) < 1e-9)
}

@Test func aReleaseInsideABurstEndsOneGestureBeforeStartingTheNext() {
    var delivery = RecognitionDelivery()
    var transform = ContactTransform()
    var phases: [ContactTransformUpdate.Phase] = []
    let spans: [Double?] = [40, 46, 52, nil, 60, 60]
    for (index, span) in spans.enumerated() {
        let receipt = deliver(&delivery, sequence: UInt64(index + 1), arrival: Double(index) * 0.008,
                              count: span == nil ? 0 : 2, drained: 0.048)
        #expect(receipt.canRecognize)
        let contacts = span.map { deliveryPair($0) } ?? []
        if let update = transform.receive(contacts, canBegin: true, at: receipt.recognitionTime,
                                           sourceTimestamp: 100 + Double(index) * 0.008) { phases.append(update.phase) }
    }
    #expect(phases == [.began, .ended])
    #expect(transform.isTracking && transform.intent == .undecided && transform.assessment.scaleRatio == 1)
}

@Test func missingFramesInterruptOnlyTheirDeviceUntilARealRelease() {
    var delivery = RecognitionDelivery()
    _ = deliver(&delivery, id: 1, sequence: 1, arrival: 0)
    _ = deliver(&delivery, id: 2, sequence: 1, arrival: 0.001)
    let gap = deliver(&delivery, id: 1, sequence: 3, arrival: 0.016)
    #expect(gap.interrupted && gap.accepted && !gap.canRecognize)
    #expect(deliver(&delivery, id: 2, sequence: 2, arrival: 0.017).canRecognize)
    #expect(!deliver(&delivery, sequence: 4, arrival: 0.024).canRecognize)
    #expect(deliver(&delivery, sequence: 5, arrival: 0.032, count: 1).canRecognize)
    #expect(deliver(&delivery, sequence: 6, arrival: 0.040, count: 0).canRecognize)
    #expect(deliver(&delivery, sequence: 7, arrival: 0.048).canRecognize)
}

@Test func initialOverflowAndDeviceReplacementCannotBeginInTheMiddleOfAPair() {
    var delivery = RecognitionDelivery()
    let overflow = deliver(&delivery, sequence: 50, arrival: 0)
    #expect(overflow.interrupted && !overflow.canRecognize)
    #expect(deliver(&delivery, sequence: 51, arrival: 0.008, count: 0).canRecognize)
    #expect(deliver(&delivery, sequence: 52, arrival: 0.016).canRecognize)
    let replacement = deliver(&delivery, stream: 2, sequence: 1, arrival: 0.024)
    #expect(replacement.interrupted && !replacement.canRecognize)
    #expect(deliver(&delivery, stream: 2, sequence: 2, arrival: 0.032, count: 0).canRecognize)
    #expect(deliver(&delivery, stream: 2, sequence: 3, arrival: 0.040).canRecognize)
}

@Test func aNativeClickCannotBeUndoneByAPreClickQueuedRelease() {
    var delivery = RecognitionDelivery()
    var transform = ContactTransform()
    _ = deliver(&delivery, sequence: 1, arrival: 0)
    _ = transform.receive(deliveryPair(), canBegin: true, at: 0)
    delivery.interrupt(deviceID: 1, at: 0.020)
    _ = transform.interrupt()
    let oldRelease = deliver(&delivery, sequence: 2, arrival: 0.016, count: 0, drained: 0.040)
    #expect(oldRelease.interrupted && !oldRelease.canRecognize)
    #expect(!deliver(&delivery, sequence: 3, arrival: 0.024, drained: 0.040).canRecognize)
    #expect(!deliver(&delivery, sequence: 4, arrival: 0.032, drained: 0.040).canRecognize)
    #expect(transform.intent == .undecided && !transform.isTracking)
    let release = deliver(&delivery, sequence: 5, arrival: 0.040, count: 0)
    #expect(release.canRecognize)
    _ = transform.receive([], canBegin: true, at: release.recognitionTime)
    let newPair = deliver(&delivery, sequence: 6, arrival: 0.048)
    #expect(newPair.canRecognize)
    _ = transform.receive(deliveryPair(), canBegin: true, at: newPair.recognitionTime)
    #expect(transform.isTracking && transform.intent == .undecided)
}

@Test func unknownClickDeviceStopsAllConnectedStreamsWithoutCrossDeviceRearming() {
    var delivery = RecognitionDelivery()
    delivery.setDevices([1, 2])
    delivery.interrupt(at: 0.020)
    #expect(!deliver(&delivery, sequence: 1, arrival: 0.024).canRecognize)
    #expect(deliver(&delivery, sequence: 2, arrival: 0.032, count: 0).canRecognize)
    #expect(deliver(&delivery, sequence: 3, arrival: 0.040).canRecognize)
    #expect(!deliver(&delivery, id: 2, sequence: 1, arrival: 0.024).canRecognize)
}

@Test func aReleaseWaitingForTheBridgeLockKeepsItsPreClickOrdering() {
    var delivery = RecognitionDelivery()
    _ = deliver(&delivery, sequence: 1, arrival: 0)
    delivery.interrupt(at: 0.020)
    let release = delivery.receive(deviceID: 1, streamID: 1, sequence: 2, receivedAt: 0.024,
        sourceTimestamp: 100.016, touchingCount: 0, drainedAt: 0.032, callbackAt: 0.016)
    #expect(!release.canRecognize)
    #expect(!deliver(&delivery, sequence: 3, arrival: 0.032).canRecognize)
    #expect(deliver(&delivery, sequence: 4, arrival: 0.040, count: 0).canRecognize)
}

@Test func anOldNativeClickDoesNotReleaseOrInterruptAnotherDevice() {
    var delivery = RecognitionDelivery()
    _ = deliver(&delivery, sequence: 1, arrival: 0)
    _ = deliver(&delivery, id: 2, sequence: 1, arrival: 0.001)
    delivery.interrupt(deviceID: 1, at: 0.020)
    delivery.interrupt(deviceID: 1, at: 0.010)
    #expect(deliver(&delivery, id: 2, sequence: 2, arrival: 0.024).canRecognize)
    #expect(!deliver(&delivery, sequence: 2, arrival: 0.016, count: 0).canRecognize)
    #expect(!deliver(&delivery, sequence: 3, arrival: 0.024).canRecognize)
}

@Test func staleBacklogCannotReplayTransformsOrRearmFromAnOldRelease() {
    var delivery = RecognitionDelivery()
    let stale = deliver(&delivery, sequence: 1, arrival: 0, drained: 1)
    #expect(stale.interrupted && !stale.canRecognize)
    #expect(!deliver(&delivery, sequence: 2, arrival: 0.008, count: 0, drained: 1).canRecognize)
    #expect(!deliver(&delivery, sequence: 3, arrival: 1, drained: 1).canRecognize)
    #expect(deliver(&delivery, sequence: 4, arrival: 1.008, count: 0).canRecognize)
    #expect(deliver(&delivery, sequence: 5, arrival: 1.016).canRecognize)
}

@Test func hostAndSourceGapsOrBackwardsClocksInvalidateContinuity() {
    for (arrival, source) in [(0.3, 100.3), (0.008, 100.3), (0.008, 99.0), (-0.001, 100.008)] {
        var delivery = RecognitionDelivery()
        _ = deliver(&delivery, sequence: 1, arrival: 0, source: 100)
        let receipt = deliver(&delivery, sequence: 2, arrival: arrival, source: source)
        if arrival < 0 { #expect(!receipt.accepted) }
        else { #expect(receipt.interrupted && !receipt.canRecognize) }
    }
}

@Test func duplicatesCannotResetContinuityAndEqualTimeNeedsNewSourceEvidence() {
    var delivery = RecognitionDelivery()
    _ = deliver(&delivery, sequence: 1, arrival: 1, source: 100)
    #expect(!deliver(&delivery, sequence: 1, arrival: 1.008, source: 100.008, count: 0).accepted)
    #expect(deliver(&delivery, sequence: 2, arrival: 1.008, source: 100.008).canRecognize)
    let repeated = deliver(&delivery, sequence: 3, arrival: 1.008, source: 100.008, count: 0)
    #expect(repeated.interrupted && !repeated.accepted && !repeated.canRecognize)
    #expect(!deliver(&delivery, sequence: 4, arrival: 1.016, source: 100.016).canRecognize)
    #expect(deliver(&delivery, sequence: 5, arrival: 1.024, source: 100.024, count: 0).canRecognize)
}

@Test func deviceRemovalClearsOnlyItsOwnSequenceHistory() {
    var delivery = RecognitionDelivery()
    _ = deliver(&delivery, sequence: 1, arrival: 0)
    _ = deliver(&delivery, id: 2, sequence: 1, arrival: 0.001)
    delivery.setDevices([1])
    #expect(deliver(&delivery, sequence: 2, arrival: 0.008).canRecognize)
    delivery.setDevices([1, 2])
    #expect(deliver(&delivery, id: 2, stream: 2, sequence: 1, arrival: 0.009).canRecognize)
}

@Test func silenceAfterReleaseOrOneFingerDoesNotRequireAnExtraLift() {
    for count in [0, 1, 3] {
        var delivery = RecognitionDelivery()
        _ = deliver(&delivery, sequence: 1, arrival: 0, count: count)
        let pair = deliver(&delivery, sequence: 2, arrival: 1)
        #expect(pair.canRecognize && !pair.interrupted)
    }
}

@Test func liftingOneFingerAfterAClickAllowsTheNextPair() {
    var delivery = RecognitionDelivery()
    _ = deliver(&delivery, sequence: 1, arrival: 0)
    delivery.interrupt(deviceID: 1, at: 0.010)
    #expect(!deliver(&delivery, sequence: 2, arrival: 0.016).canRecognize)
    #expect(deliver(&delivery, sequence: 3, arrival: 0.024, count: 1).canRecognize)
    #expect(deliver(&delivery, sequence: 4, arrival: 0.032).canRecognize)
}
