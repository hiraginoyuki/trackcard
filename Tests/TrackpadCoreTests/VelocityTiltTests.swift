import CoreGraphics
import Testing
@testable import TrackpadCore

private func velocityPair(angle: Double = 0, distance: Double = 40, axis: Double = 0,
                          offset: Double = 0, round: Bool = false, reverseArea: Bool = false) -> [TransformContact] {
    [TransformContact(id: 1, positionMM: CGPoint(x: offset - distance / 2 * cos(angle), y: -distance / 2 * sin(angle)),
                      orientation: axis, radiiMM: CGSize(width: round ? 8 : reverseArea ? 6 : 9, height: round ? 8 : 4)),
     TransformContact(id: 2, positionMM: CGPoint(x: offset + distance / 2 * cos(angle), y: distance / 2 * sin(angle)),
                      orientation: axis, radiiMM: CGSize(width: reverseArea ? 12 : 6, height: 4))]
}

@Test func velocityTiltRecognizesOpposedTangentialMotionBeforeTheFallbackWindow() {
    for model in [ContactTransform.Configuration.TiltModel.vectors, .vectorsAndAxis] {
        var transform = ContactTransform(configuration: .init(tiltModel: model))
        var beganAt: Double?
        for index in 0...12 {
            let t = Double(index) / 100
            let angle = t * .pi / 3
            if transform.receive(velocityPair(angle: angle, axis: angle), canBegin: true, at: t)?.phase == .began {
                beganAt = t; break
            }
        }
        #expect(transform.intent == .rotation && beganAt != nil && (beganAt ?? 1) < 0.096)
        #expect((transform.assessment.tiltFeatures?.angularVelocity ?? 0) > 0)
    }
}

@Test func radialAndParallelVelocityCannotSupplyTiltEvidence() {
    for radial in [false, true] {
        var evidence = VelocityTiltEvidence()
        var features: VelocityTiltFeatures?
        for index in 0...12 {
            features = evidence.receive(velocityPair(distance: radial ? 40 + Double(index) : 40,
                                                     offset: radial ? 0 : Double(index)), at: Double(index) / 100, useAxis: true)
        }
        #expect((features?.confidence ?? 1) < 0.01)
        #expect(abs(features?.angularVelocity ?? 1) < 1e-8)
    }
}

@Test func thumbCandidateUsesInitialAreaAndAxisDerivativeWrapsModuloPi() {
    var evidence = VelocityTiltEvidence()
    var features: VelocityTiltFeatures?
    for index in 0...6 {
        let degrees = 89 + Double(index) * 0.5
        let wrapped = degrees >= 90 ? degrees - 180 : degrees
        features = evidence.receive(velocityPair(axis: wrapped * .pi / 180, reverseArea: index > 2),
                                    at: Double(index) / 100, useAxis: true)
    }
    #expect(features?.thumbCandidateID == 1)
    #expect(abs((features?.thumbAxisVelocity ?? 100) * 180 / .pi - 50) < 1e-6)
    #expect(abs((features?.thumbRelativeVelocity ?? 100) * 180 / .pi - 50) < 1e-6)
}

@Test func roundOrInterruptedContactAxesHaveNoInventedDerivative() {
    var evidence = VelocityTiltEvidence()
    for index in 0...5 { _ = evidence.receive(velocityPair(axis: Double(index) / 100), at: Double(index) / 100, useAxis: true) }
    let round = evidence.receive(velocityPair(axis: 1, round: true), at: 0.06, useAxis: true)
    #expect(round?.thumbAxisVelocity == nil && round?.thumbRelativeAngle == nil)
    let resumed = evidence.receive(velocityPair(axis: 1.5), at: 0.07, useAxis: true)
    #expect(resumed?.thumbAxisVelocity == nil)
    #expect(evidence.receive(velocityPair(axis: 2), at: 0.2, useAxis: true) == nil)
}

@Test func opacityRetargetingPreservesDisplayedValueAndVelocityWhileReversing() {
    var opacity = OpacityMotion(value: 0)
    opacity.reset(to: 0, at: 0); opacity.retarget(to: 0.5)
    opacity.advance(at: 0.02)
    let before = opacity.value, velocity = opacity.velocity
    opacity.retarget(to: 0.1)
    #expect(opacity.value == before && opacity.velocity == velocity)
    for index in 3...40 { opacity.advance(at: Double(index) / 100) }
    #expect(abs(opacity.value - 0.1) < 1e-4)
    opacity.retarget(to: 1)
    for index in 41...60 { opacity.advance(at: Double(index) / 100, maximum: 0.2); #expect(opacity.value <= 0.2 + 1e-9) }
    opacity.retarget(to: 0)
    opacity.advance(at: 0.61, reduceMotion: true)
    #expect(opacity.value == 0)
}
