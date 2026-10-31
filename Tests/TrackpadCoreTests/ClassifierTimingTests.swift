import CoreGraphics
import Foundation
import Testing
@testable import TrackpadCore

@Test func completedTimersAgreeOnReadinessProgressAndRemainingTime() {
    for origin in [0.0, 160551.135, 1_000_000, 1_000_000_000] {
        for duration in [0.008, 0.016, 0.024, 0.032, 0.096] {
            for observationOnly in [false, true] {
                for direction in [-1, 1] {
                    var bank = GestureClassifierBank()
                    let signal = GestureClassifierSignal(classifier: .relativeTilt, confidence: 1, eligible: true,
                        direction: direction, persistence: observationOnly ? 0 : duration,
                        observationWindow: observationOnly ? duration : 0)
                    _ = bank.receive([signal], at: 0, sourceResolution: origin.ulp)
                    let deadline = (origin + duration) - origin
                    let assessment = bank.receive([signal], at: deadline, sourceResolution: origin.ulp)[0]
                    #expect(assessment.isReady && assessment.progress == 1)
                    #expect(assessment.persistenceRemaining == 0 && assessment.observationRemaining == 0)
                    #expect(assessment.blockers.isEmpty)
                }
            }
        }
    }
}

@Test func aSampleOneMicrosecondEarlyCannotCompleteEitherTimer() {
    for origin in [0.0, 160551.135, 1_000_000, 1_000_000_000] {
        for duration in [0.008, 0.016, 0.024, 0.032, 0.096] {
            for observationOnly in [false, true] {
                var bank = GestureClassifierBank()
                let signal = GestureClassifierSignal(classifier: .relativeTilt, confidence: 1, eligible: true,
                    persistence: observationOnly ? 0 : duration, observationWindow: observationOnly ? duration : 0)
                _ = bank.receive([signal], at: 0, sourceResolution: origin.ulp)
                let early = (origin + duration - 0.000001) - origin
                let assessment = bank.receive([signal], at: early, sourceResolution: origin.ulp)[0]
                #expect(!assessment.isReady && assessment.progress < 1)
                #expect(observationOnly ? assessment.observationRemaining > 0 : assessment.persistenceRemaining > 0)
                #expect(!assessment.blockers.isEmpty)
            }
        }
    }
}

@Test func coarseClockResolutionCannotEraseAPersistenceRequirement() {
    var bank = GestureClassifierBank()
    let signal = GestureClassifierSignal(classifier: .relativeTilt, confidence: 1, eligible: true, persistence: 0.016)
    #expect(!bank.receive([signal], at: 0, sourceResolution: 1)[0].isReady)
    #expect(!bank.receive([signal], at: 0.015999, sourceResolution: 1)[0].isReady)
    #expect(bank.receive([signal], at: 0.016, sourceResolution: 1)[0].isReady)
}

@Test func correctedDeadlineSurvivesTheEvidenceResetThatUsedToMissIt() {
    for policy in [ContactTransform.Configuration.TimingPolicy.sourceClock, .legacyRelative] {
        var bank = GestureClassifierBank()
        func signal(eligible: Bool) -> GestureClassifierSignal {
            .init(classifier: .relativeTilt, confidence: eligible ? 1 : 0, eligible: eligible, persistence: 0.016)
        }
        _ = bank.receive([signal(eligible: true)], at: 0.024000000004889444, timingPolicy: policy)
        let boundary = bank.receive([signal(eligible: true)], at: 0.03999999997904524, timingPolicy: policy)[0]
        #expect(boundary.isReady == (policy == .sourceClock))
        if policy == .sourceClock {
            #expect(boundary.progress == 1 && boundary.persistenceRemaining == 0 && boundary.blockers.isEmpty)
        }
        _ = bank.receive([signal(eligible: false)], at: 0.048, timingPolicy: policy)
        #expect(!bank.receive([signal(eligible: true)], at: 0.056, timingPolicy: policy)[0].isReady)
        #expect(bank.receive([signal(eligible: true)], at: 0.073, timingPolicy: policy)[0].isReady)
    }
}

@Test func persistenceAndObservationStillHaveToCompleteIndependently() {
    var bank = GestureClassifierBank()
    func signal(eligible: Bool) -> GestureClassifierSignal {
        .init(classifier: .geometryTilt, confidence: 1, eligible: eligible, persistence: 0.032, observationWindow: 0.096)
    }
    _ = bank.receive([signal(eligible: false)], at: 0)
    _ = bank.receive([signal(eligible: true)], at: 0.080)
    let observationComplete = bank.receive([signal(eligible: true)], at: 0.096)[0]
    #expect(!observationComplete.isReady && observationComplete.observationRemaining == 0)
    #expect(observationComplete.persistenceRemaining > 0)
    #expect(bank.receive([signal(eligible: true)], at: 0.112)[0].isReady)
}

@Test func sourcePrecisionReachesTheClassifierAndSurvivesReleaseAndInterruption() {
    for origin in [160551.135, 1_000_000_000] {
        var transform = ContactTransform()
        func pair(degrees: Double) -> [TransformContact] {
            let angle = degrees * .pi / 180
            return [TransformContact(id: 1, positionMM: CGPoint(x: -20 * cos(angle), y: -20 * sin(angle))),
                    TransformContact(id: 2, positionMM: CGPoint(x: 20 * cos(angle), y: 20 * sin(angle)))]
        }
        for episode in 0..<3 {
            let start = Double(episode)
            _ = transform.receive(pair(degrees: 0), canBegin: true, at: start, sourceTimestamp: origin + start)
            _ = transform.receive(pair(degrees: 3), canBegin: true, at: start + 0.008, sourceTimestamp: origin + start + 0.008)
            let update = transform.receive(pair(degrees: 6), canBegin: true, at: start + 0.016, sourceTimestamp: origin + start + 0.016)
            #expect(update?.phase == .began && transform.committedClassifier == .decisiveTangentialTilt)
            let assessment = transform.assessment.classifiers.first { $0.classifier == .decisiveTangentialTilt }!
            #expect(assessment.isReady && assessment.progress == 1 && assessment.persistenceRemaining == 0)
            _ = transform.interrupt()
            #expect(transform.receive(pair(degrees: 9), canBegin: true, at: start + 0.024,
                                      sourceTimestamp: origin + start + 0.024) == nil)
            _ = transform.receive([], canBegin: false, at: start + 0.032)
        }
    }
}

@Test func recordedTurnCommitsAtItsDeadlineBeforeTheEvidenceWeakens() {
    // g7009: positions and source timestamps preserve the missed 40 ms
    // deadline. Ellipse metadata is unnecessary for the relative-turn path.
    let samples: [(Double, Double, Double, Double, Double)] = [
        (160551.135, 115.3933759689331, 65.2585693359375, 78.45613861083984, 19.970448303222657),
        (160551.143, 114.5520486831665, 65.93207702636718, 78.3547794342041, 19.91942596435547),
        (160551.151, 113.81208801269531, 66.16678161621094, 78.28382205963135, 19.929629516601562),
        (160551.159, 113.23430500030517, 66.22800750732422, 78.2331350326538, 20.052085876464844),
        (160551.167, 112.46393508911133, 66.3096450805664, 78.21286468505859, 20.327611541748045),
        (160551.175, 111.55165786743164, 66.31985321044921, 78.24327392578125, 20.63375015258789),
        (160551.183, 110.53801403045654, 66.16678161621094, 78.29395351409912, 20.909273529052733)
    ]
    var comparison = ClassifierComparison()
    for (index, sample) in samples.enumerated() {
        let contacts = [TransformContact(id: 5, positionMM: CGPoint(x: sample.1, y: sample.2)),
                        TransformContact(id: 10, positionMM: CGPoint(x: sample.3, y: sample.4))]
        comparison.receive(contacts, at: Double(index) * 0.008, sourceTimestamp: sample.0)
    }
    let current = comparison.traces.first { $0.variant.isCurrent }!
    let previous = comparison.traces.first { $0.variant.id == "relative-turn" }!
    #expect(current.decision == .rotation && current.committedClassifier == .relativeTilt)
    #expect(abs((current.decisionTime ?? 0) - 0.040) < 1e-9)
    #expect(previous.decision == .undecided && previous.decisionTime == nil)
}
