import CoreGraphics
import Foundation
import Testing
@testable import TrackpadCore

private func translatedTurn(degrees: Double, translation: Double, axis: Double? = nil) -> [TransformContact] {
    let angle = degrees * .pi / 180
    return [
        TransformContact(id: 1, positionMM: CGPoint(x: translation - 20 * cos(angle), y: -20 * sin(angle)),
                         orientation: axis, radiiMM: CGSize(width: 8, height: 4)),
        TransformContact(id: 2, positionMM: CGPoint(x: translation + 20 * cos(angle), y: 20 * sin(angle)),
                         orientation: axis, radiiMM: CGSize(width: 6, height: 3))
    ]
}

@Test func aRelativeTurnCanCommitWhileCommonMovementWeakensVelocityCoordination() {
    for direction in [-1.0, 1.0] {
        var current = ContactTransform()
        var previous = ContactTransform(configuration: .init(usesRelativeTurn: false))
        for index in 0...5 {
            let contacts = translatedTurn(degrees: Double(index) * 0.8 * direction,
                                          translation: Double(index) * 0.45)
            _ = current.receive(contacts, canBegin: true, at: Double(index) * 0.008)
            _ = previous.receive(contacts, canBegin: true, at: Double(index) * 0.008)
        }
        #expect(current.intent == .rotation && current.committedClassifier == .relativeTilt)
        #expect(abs(current.elapsed - 0.040) < 1e-9)
        #expect(previous.intent == .undecided)
        #expect(current.assessment.tiltFeatures!.confidence < 0.7)
        #expect(current.assessment.classifiers.filter { $0.classifier.intent == .rotation && $0.classifier != .relativeTilt }
            .allSatisfy { !$0.isReady })
    }
}

@Test func aMeasuredTurnHoldsTheSwipeFallbackUntilItsOwnPersistenceCompletes() {
    var current = ContactTransform(configuration: .init(usesEarlyIntent: false))
    var previous = ContactTransform(configuration: .init(usesEarlyIntent: false, usesRelativeTurn: false))
    let samples: [(Double, Double, Double)] = [(0, 0, 0), (0.100, 0, 2.8),
                                              (0.108, 3.5, 3.2), (0.116, 4, 3.4), (0.124, 4.5, 3.6)]
    for (time, degrees, translation) in samples {
        let contacts = translatedTurn(degrees: degrees, translation: translation)
        _ = current.receive(contacts, canBegin: true, at: time)
        _ = previous.receive(contacts, canBegin: true, at: time)
        if time == 0.108 {
            #expect(previous.intent == .movement && previous.committedClassifier == .translationSwipe)
            #expect(current.intent == .undecided)
            let swipe = current.assessment.classifiers.first { $0.classifier == .translationSwipe }!
            #expect(swipe.blockers.contains { $0.contains("Shared versus angular travel during turn") })
            let turn = current.assessment.classifiers.first { $0.classifier == .relativeTilt }!
            #expect(turn.checks.allSatisfy(\.passed) && !turn.isReady)
        }
        if time == 0.116 { #expect(current.intent == .undecided) }
    }
    #expect(current.intent == .rotation && current.committedClassifier == .relativeTilt)
}

@Test func anInterruptedRelativeTurnMustEarnItsSixteenMillisecondsAgain() {
    var transform = ContactTransform(configuration: .init(usesEarlyIntent: false))
    let samples: [(Double, Double, Double)] = [(0, 0, 0), (0.100, 0, 2.8),
        (0.108, 3.5, 3.2), (0.116, 0, 2.8), (0.124, 3.5, 3.2), (0.132, 4, 3.4), (0.140, 4.5, 3.6)]
    for (time, degrees, translation) in samples {
        _ = transform.receive(translatedTurn(degrees: degrees, translation: translation), canBegin: true, at: time)
        if time < 0.140 { #expect(transform.intent == .undecided) }
        if time == 0.116 {
            #expect(transform.assessment.classifiers.first { $0.classifier == .relativeTilt }?.progress == 0)
        }
    }
    #expect(transform.intent == .rotation && transform.committedClassifier == .relativeTilt)
}

@Test func aRelativeTurnDoesNotNeedSmoothEllipseAngles() {
    var missingAxis = ContactTransform(configuration: .init(tiltModel: .vectorsAndAxis))
    var coarseAxis = ContactTransform(configuration: .init(tiltModel: .vectorsAndAxis))
    for index in 0...5 {
        let degrees = Double(index) * 0.8, translation = Double(index) * 0.45
        _ = missingAxis.receive(translatedTurn(degrees: degrees, translation: translation),
                                canBegin: true, at: Double(index) * 0.008)
        _ = coarseAxis.receive(translatedTurn(degrees: degrees, translation: translation,
                                              axis: Double(index % 16) * .pi / 16),
                               canBegin: true, at: Double(index) * 0.008)
        #expect(missingAxis.intent == coarseAxis.intent)
        #expect(missingAxis.committedClassifier == coarseAxis.committedClassifier)
    }
    #expect(missingAxis.committedClassifier == .relativeTilt)
}
