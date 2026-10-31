import CoreGraphics
import Foundation
import Testing
@testable import TrackpadCore

private func independentPair(span: Double = 40, degrees: Double = 0,
                             center: CGPoint = .zero) -> [TransformContact] {
    let angle = degrees * .pi / 180
    return [TransformContact(id: 1, positionMM: CGPoint(x: center.x - span / 2 * cos(angle), y: center.y - span / 2 * sin(angle))),
            TransformContact(id: 2, positionMM: CGPoint(x: center.x + span / 2 * cos(angle), y: center.y + span / 2 * sin(angle)))]
}

@Test func oneClassifierCanFireWhileEveryOtherClassifierHasZeroConfidence() {
    for winner in GestureClassifier.allCases {
        var bank = GestureClassifierBank()
        let signals = GestureClassifier.allCases.map {
            GestureClassifierSignal(classifier: $0, confidence: $0 == winner ? 1 : 0,
                                    eligible: $0 == winner, persistence: 0.024)
        }
        #expect(GestureClassifierBank.winner(in: bank.receive(signals, at: 0)) == nil)
        let assessments = bank.receive(signals, at: 0.024)
        #expect(GestureClassifierBank.winner(in: assessments) == winner)
        #expect(assessments.filter { $0.classifier != winner }.allSatisfy { $0.confidence == 0 && !$0.isReady })
    }
}

@Test func weakSiblingClassifiersDoNotDiluteTheStrongClassifiersScore() {
    var bank = GestureClassifierBank()
    let assessments = bank.receive([
        .init(classifier: .radialPinch, confidence: 1, eligible: true),
        .init(classifier: .spacingPinch, confidence: 0.1, eligible: false),
        .init(classifier: .geometryPinch, confidence: 0.2, eligible: false)
    ], at: 0)
    #expect(GestureClassifierBank.winner(in: assessments) == .radialPinch)
    #expect(assessments.first?.confidence == 1)
}

@Test func anInterruptedClassifierDoesNotResetItsSiblingTimer() {
    var bank = GestureClassifierBank()
    func signals(interrupted: Bool) -> [GestureClassifierSignal] {
        [.init(classifier: .radialPinch, confidence: interrupted ? 0 : 1, eligible: !interrupted,
               persistence: 0.024),
         .init(classifier: .spacingPinch, confidence: 1, eligible: true, persistence: 0.032)]
    }
    _ = bank.receive(signals(interrupted: false), at: 0)
    _ = bank.receive(signals(interrupted: true), at: 0.016)
    let assessments = bank.receive(signals(interrupted: false), at: 0.032)
    #expect(GestureClassifierBank.winner(in: assessments) == .spacingPinch)
    #expect(assessments.first { $0.classifier == .radialPinch }?.isReady == false)
}

@Test func directionReversalAndMissingPathsResetOnlyTheirOwnEvidence() {
    var bank = GestureClassifierBank()
    _ = bank.receive([.init(classifier: .radialPinch, confidence: 1, eligible: true, direction: 1, persistence: 0.024),
                      .init(classifier: .tangentialTilt, confidence: 1, eligible: true, direction: 1, persistence: 0.024)], at: 0)
    let reversed = bank.receive([
        .init(classifier: .radialPinch, confidence: 1, eligible: true, direction: -1, persistence: 0.024),
        .init(classifier: .tangentialTilt, confidence: 1, eligible: true, direction: 1, persistence: 0.024)
    ], at: 0.024)
    #expect(GestureClassifierBank.winner(in: reversed) == .tangentialTilt)
    _ = bank.receive([], at: 0.032)
    #expect(GestureClassifierBank.winner(in: bank.receive([
        .init(classifier: .tangentialTilt, confidence: 1, eligible: true, direction: 1, persistence: 0.024)
    ], at: 0.048)) == nil)
}

@Test func simultaneousCrossingsHaveStableOwnershipRegardlessOfArrayOrder() {
    let signals = GestureClassifier.allCases.map { GestureClassifierSignal(classifier: $0, confidence: 1, eligible: true) }
    for order in [signals, Array(signals.reversed())] {
        var bank = GestureClassifierBank()
        #expect(GestureClassifierBank.winner(in: bank.receive(order, at: 0)) == .coordinatedSwipe)
    }
}

@Test func radialMotionCanCommitWithoutSpacingOrGeometryBeingReady() {
    var transform = ContactTransform()
    for (index, span) in [44.0, 39.4, 32, 26].enumerated() {
        _ = transform.receive(independentPair(span: span, degrees: Double(index) * 2.2),
                              canBegin: true, at: Double(index) * 0.015)
    }
    #expect(transform.intent == .pinch && transform.committedClassifier == .radialPinch)
    #expect(transform.assessment.classifiers.filter { $0.classifier.intent == .pinch && $0.classifier != .radialPinch }
        .allSatisfy { !$0.isReady })
}

@Test func spacingCanCommitWhileTheVelocityAndFallbackClassifiersAreWeak() {
    var transform = ContactTransform()
    _ = transform.receive(independentPair(), canBegin: true, at: 0)
    _ = transform.receive(independentPair(span: 42.5), canBegin: true, at: 0.01)
    _ = transform.receive(independentPair(span: 42.5), canBegin: true, at: 0.043)
    #expect(transform.intent == .pinch && transform.committedClassifier == .spacingPinch)
    #expect(transform.assessment.classifiers.filter { $0.classifier.intent == .pinch && $0.classifier != .spacingPinch }
        .allSatisfy { $0.confidence < 1 && !$0.isReady })
}

@Test func tiltGeometryCanFireAfterTangentialVelocityHasDiedAway() {
    var transform = ContactTransform()
    _ = transform.receive(independentPair(), canBegin: true, at: 0)
    // A step beyond the velocity observer's maximum interval, followed by
    // no new movement: only the geometric fallback has sustained evidence.
    for time in [0.06, 0.10, 0.14, 0.16] {
        _ = transform.receive(independentPair(degrees: 3), canBegin: true, at: time)
    }
    #expect(transform.intent == .rotation && transform.committedClassifier == .geometryTilt)
    #expect(transform.assessment.classifiers.first { $0.classifier == .tangentialTilt }?.confidence == 0)
}

@Test func tangentialMotionCanFireBeforeTheTiltGeometryWindow() {
    var transform = ContactTransform()
    for index in 0...6 {
        _ = transform.receive(independentPair(degrees: Double(index) * 0.5), canBegin: true, at: Double(index) * 0.015)
    }
    #expect(transform.intent == .rotation && transform.committedClassifier == .tangentialTilt)
    #expect(transform.assessment.classifiers.first { $0.classifier == .geometryTilt }?.isReady == false)
}

@Test func decisiveMotionCanCommitAfterEightMillisecondsOfItsOwnEvidence() {
    for pinch in [false, true] {
        var transform = ContactTransform()
        _ = transform.receive(independentPair(), canBegin: true, at: 0)
        let first = independentPair(span: pinch ? 46 : 40, degrees: pinch ? 0 : 3)
        #expect(transform.receive(first, canBegin: true, at: 0.008) == nil)
        let second = independentPair(span: pinch ? 52 : 40, degrees: pinch ? 0 : 6)
        #expect(transform.receive(second, canBegin: true, at: 0.016)?.phase == .began)
        #expect(transform.committedClassifier == (pinch ? .decisiveRadialPinch : .decisiveTangentialTilt))
        #expect(transform.assessment.classifiers.first { $0.classifier == (pinch ? .radialPinch : .tangentialTilt) }?.isReady == false)
    }
}

@Test func mixedPinchGeometryCanFireWithoutTheFastPinchClassifiers() {
    var transform = ContactTransform()
    _ = transform.receive(independentPair(), canBegin: true, at: 0)
    for time in [0.01, 0.04, 0.07, 0.10, 0.11] {
        _ = transform.receive(independentPair(span: 44, degrees: 1.5), canBegin: true, at: time)
    }
    #expect(transform.intent == .pinch && transform.committedClassifier == .geometryPinch)
    #expect(transform.assessment.classifiers.filter { $0.classifier.intent == .pinch && $0.classifier != .geometryPinch }
        .allSatisfy { !$0.isReady })
}

@Test func slowSharedTravelCanFireWithoutCoordinatedVelocityConfidence() {
    var transform = ContactTransform()
    for index in 0...3 {
        _ = transform.receive(independentPair(center: CGPoint(x: index, y: 0)), canBegin: true, at: Double(index) * 0.1)
    }
    #expect(transform.intent == .movement && transform.committedClassifier == .translationSwipe)
    #expect(transform.assessment.classifiers.first { $0.classifier == .coordinatedSwipe }?.confidence == 0)
}

@Test func pinchFallbackCannotRaceAnAmbiguousTurnUsingOlderSpacingEvidence() {
    var transform = ContactTransform(configuration: .init(usesRelativeMotion: false))
    _ = transform.receive(independentPair(), canBegin: true, at: 0)
    _ = transform.receive(independentPair(span: 44, degrees: 1.5), canBegin: true, at: 0.01)
    for time in [0.05, 0.08] {
        _ = transform.receive(independentPair(span: 44, degrees: 5), canBegin: true, at: time)
        #expect(transform.intent == .undecided)
    }
    _ = transform.receive(independentPair(span: 44, degrees: 5), canBegin: true, at: 0.11)
    #expect(transform.intent == .rotation && transform.committedClassifier == .geometryTilt)
}

@Test func scoresAreIndependentWhileTheCommittedClassifierStaysLatched() {
    var transform = ContactTransform()
    _ = transform.receive(independentPair(), canBegin: true, at: 0)
    _ = transform.receive(independentPair(span: 44), canBegin: true, at: 0.01)
    _ = transform.receive(independentPair(span: 44), canBegin: true, at: 0.043)
    #expect(transform.committedClassifier == .spacingPinch)
    _ = transform.receive(independentPair(span: 44, degrees: 20), canBegin: true, at: 0.06)
    #expect(transform.intent == .pinch && transform.committedClassifier == .spacingPinch)
    #expect(transform.assessment.scores.pinch + transform.assessment.scores.rotation + transform.assessment.scores.movement > 1)
    _ = transform.receive([], canBegin: false, at: 0.07)
    #expect(transform.committedClassifier == nil && transform.assessment.classifiers.isEmpty)
}

@Test func comparisonKeepsIndependentEvidenceAndTheActualFiringPath() {
    var comparison = ClassifierComparison()
    comparison.receive(independentPair(), at: 0)
    comparison.receive(independentPair(center: CGPoint(x: 0.9, y: 0)), at: 0.008)
    let current = comparison.traces.first { $0.variant.isCurrent }!
    #expect(current.decision == .movement && current.committedClassifier == .coordinatedSwipe)
    #expect(current.samples.last?.classifiers.count == GestureClassifier.allCases.count)
    #expect(comparison.traces.filter { !$0.variant.configuration.usesIndependentClassifiers }.allSatisfy { $0.samples.last?.classifiers.isEmpty == true })
    comparison.receiveRightClick(at: 0.01)
    #expect(comparison.traces.first { $0.variant.isCurrent }?.committedClassifier == .coordinatedSwipe)
}

@Test func diagnosticsNameTheMeasuredInputAndThresholdHoldingAClassifierBack() {
    var transform = ContactTransform()
    _ = transform.receive(independentPair(), canBegin: true, at: 0)
    _ = transform.receive(independentPair(span: 40.5), canBegin: true, at: 0.008)
    let radial = transform.assessment.classifiers.first { $0.classifier == .radialPinch }!
    #expect(radial.checks.contains { $0.name == "Radial speed" && $0.threshold == 60 && $0.unit == "mm/s" })
    #expect(radial.blockers.contains { $0.contains("Radial speed") && $0.contains("needs ≥ 60 mm/s") })
    #expect(radial.blockers.contains { $0.contains("Radial travel") })
    #expect(!radial.isReady && radial.confidence < 1)
}

@Test func highEvidenceExplainsItsOwnRemainingPersistenceBeforeFiring() {
    var transform = ContactTransform()
    _ = transform.receive(independentPair(), canBegin: true, at: 0)
    _ = transform.receive(independentPair(span: 46), canBegin: true, at: 0.008)
    let decisive = transform.assessment.classifiers.first { $0.classifier == .decisiveRadialPinch }!
    #expect(decisive.checks.allSatisfy(\.passed) && decisive.confidence == 1 && !decisive.isReady)
    #expect(decisive.blockers == ["Persistence: 8 ms remaining"])
}

@Test func tiltSuppressionReportsTheCursorEntryPriorAndItsWeightedInputs() {
    var transform = ContactTransform()
    _ = transform.receive([TransformContact(id: 1, positionMM: CGPoint(x: -22, y: 0))], canBegin: false, at: 0)
    _ = transform.receive([TransformContact(id: 1, positionMM: CGPoint(x: -20, y: 0))], canBegin: false, at: 0.008)
    _ = transform.receive(independentPair(), canBegin: true, at: 0.016)
    _ = transform.receive(independentPair(degrees: 3), canBegin: true, at: 0.024)
    let tilt = transform.assessment.classifiers.filter { $0.classifier.intent == .rotation }
    #expect(tilt.count == GestureClassifier.allCases.filter { $0.intent == .rotation }.count)
    #expect(tilt.allSatisfy { $0.prior == 0.05 && !$0.isReady })
    #expect(tilt.allSatisfy { $0.blockers.contains { $0.contains("after prior") } })
}

@Test func geometryObservationDoesNotBorrowTimeFromItsPersistenceRequirement() {
    var bank = GestureClassifierBank()
    func signal(eligible: Bool, evidence: Bool) -> [GestureClassifierSignal] {
        [.init(classifier: .geometryPinch, confidence: eligible ? 1 : 0.5, eligible: eligible,
               persistence: 0.032, hasEvidence: evidence, observationWindow: 0.096)]
    }
    _ = bank.receive(signal(eligible: false, evidence: true), at: 0)
    _ = bank.receive(signal(eligible: false, evidence: false), at: 0.05)
    #expect(GestureClassifierBank.winner(in: bank.receive(signal(eligible: true, evidence: true), at: 0.1)) == nil)
    #expect(GestureClassifierBank.winner(in: bank.receive(signal(eligible: true, evidence: true), at: 0.12)) == nil)
    #expect(GestureClassifierBank.winner(in: bank.receive(signal(eligible: true, evidence: true), at: 0.132)) == .geometryPinch)
}

@Test func inspectingEarlierEvidenceDoesNotApplyAFutureLockOrClickVeto() {
    var comparison = ClassifierComparison()
    comparison.receive(independentPair(), at: 0)
    comparison.receive(independentPair(center: CGPoint(x: 0.9, y: 0)), at: 0.008)
    comparison.receiveRightClick(at: 0.012)
    let trace = comparison.traces.first { $0.variant.isCurrent }!
    let earlier = trace.inspection(at: 0)
    #expect(earlier.committedClassifier == nil && !earlier.isVetoed && !earlier.isCommitFrame)
    let commitment = trace.inspection(at: 0.008)
    #expect(commitment.committedClassifier == .coordinatedSwipe && commitment.isCommitFrame && !commitment.isVetoed)
    let veto = trace.inspection()
    #expect(abs(veto.time - 0.012) < 1e-9 && veto.isVetoed && !veto.isCommitFrame)
    #expect(trace.inspection(at: .nan).time == veto.time)
}
