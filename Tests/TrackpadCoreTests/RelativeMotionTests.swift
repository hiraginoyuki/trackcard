import CoreGraphics
import Testing
@testable import TrackpadCore

private func relativePair(span: Double, degrees: Double = 0) -> [TransformContact] {
    let angle = degrees * .pi / 180
    return [TransformContact(id: 1, positionMM: CGPoint(x: -span / 2 * cos(angle), y: -span / 2 * sin(angle))),
            TransformContact(id: 2, positionMM: CGPoint(x: span / 2 * cos(angle), y: span / 2 * sin(angle)))]
}

@Test func briefRadialPinchesRecognizeDespiteIncidentalRotation() throws {
    // Four samples at the external trackpad's 15 ms cadence: the entire
    // pair can lift before the legacy mixed-evidence window has elapsed.
    for spans in [[44.0, 39.4, 32, 26], [30.0, 34, 40, 47]] {
        var transform = ContactTransform()
        var began: ContactTransformUpdate?
        var spanAtBeginning: Double?
        var accumulatedScale = 1.0
        for index in spans.indices {
            let update = transform.receive(relativePair(span: spans[index], degrees: Double(index) * 1.2),
                                           canBegin: true, at: Double(index) * 0.015)
            if let update {
                accumulatedScale *= 1 + update.magnification
                if update.phase == .began { began = update; spanAtBeginning = spans[index] }
            }
        }
        let update = try #require(began)
        #expect(update.kind == .magnify && transform.intent == .pinch)
        #expect(transform.elapsed <= 0.045 + 1e-9)
        #expect(abs(update.magnification - (spanAtBeginning! / spans[0] - 1)) < 1e-9)
        #expect(abs(accumulatedScale - spans.last! / spans[0]) < 1e-9)
        #expect(transform.receive([], canBegin: false, at: 0.05)?.phase == .ended)
    }
}

@Test func relativeMotionUsesTheSensorClockThroughBluetoothBatches() {
    var transform = ContactTransform()
    for (index, span) in [44.0, 39.4, 32, 26].enumerated() {
        _ = transform.receive(relativePair(span: span, degrees: Double(index) * 1.2), canBegin: true,
                              at: 10 + Double(index) * 0.000001, sourceTimestamp: 100 + Double(index) * 0.015)
    }
    #expect(transform.intent == .pinch && abs(transform.elapsed - 0.045) < 1e-8)
}

@Test func radialDirectionReversalsCannotAccumulateEarlyConfidence() {
    var transform = ContactTransform()
    for (index, span) in [40.0, 44, 35, 46, 32].enumerated() {
        #expect(transform.receive(relativePair(span: span), canBegin: true, at: Double(index) * 0.015) == nil)
    }
    #expect(transform.intent == .undecided)
}

@Test func radialAndTangentialVelocityRemainDistinctPhysicalInputs() throws {
    for rotating in [false, true] {
        var evidence = VelocityTiltEvidence()
        var features: VelocityTiltFeatures?
        for index in 0...5 {
            features = evidence.receive(relativePair(span: rotating ? 40 : 40 + Double(index) * 3,
                                                     degrees: rotating ? Double(index) * 4 : 0),
                                        at: Double(index) * 0.015, useAxis: false)
        }
        let value = try #require(features)
        if rotating {
            #expect(abs(value.tangentialVelocity) > abs(value.radialVelocity) * 3)
            #expect(value.confidence > 0.8 && value.pinchConfidence < 0.2)
        } else {
            #expect(value.radialVelocity > 60 && abs(value.tangentialVelocity) < 1e-8)
            #expect(value.pinchConfidence > 0.95 && value.confidence < 0.01)
        }
    }
}

@Test func aSlowMixedLandingStillWaitsInsteadOfTakingTheFastRadialPath() {
    var transform = ContactTransform()
    _ = transform.receive(relativePair(span: 40), canBegin: true, at: 0)
    for index in 1...6 {
        let time = Double(index) * 0.015
        #expect(transform.receive(relativePair(span: 40 + time * 40, degrees: Double(index) * 0.25),
                                  canBegin: true, at: time) == nil)
    }
    #expect(transform.intent == .undecided)
}
