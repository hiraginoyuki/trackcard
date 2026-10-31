import CoreGraphics
import Foundation
import Testing
@testable import TrackpadCore

private func boundaryPair(span: Double, degrees: Double, center: CGPoint = .zero,
                          orientation: Double? = nil) -> [TransformContact] {
    let angle = degrees * .pi / 180
    return [TransformContact(id: 1, positionMM: CGPoint(x: center.x - span / 2 * cos(angle), y: center.y - span / 2 * sin(angle)),
                             orientation: orientation, radiiMM: CGSize(width: 8, height: 4)),
            TransformContact(id: 2, positionMM: CGPoint(x: center.x + span / 2 * cos(angle), y: center.y + span / 2 * sin(angle)),
                             orientation: orientation, radiiMM: CGSize(width: 6, height: 3))]
}

private func mixedPinch(_ index: Int, direction: Double = 1, orientation: Double? = nil) -> [TransformContact] {
    let time = Double(index) * 0.008
    return boundaryPair(span: 52 - time * 120, degrees: time * 80 * direction, orientation: orientation)
}

// A reduced physical envelope from the older spacing-led Tilt counterexample.
// Span (mm), turn (degrees), and center displacement in the initial pair axes.
// Each row is 15 ms apart; ellipse metadata and absolute device coordinates
// have no role in this regression.
private let developingTurn: [(Double, Double, Double, Double)] = [
    (52.4285, 0, 0, 0), (52.4519, -0.1189, 0.0237, 0.0042),
    (52.4103, -0.2609, 0.0326, 0.0104), (52.4043, -0.2929, 0.0178, 0.0125),
    (52.3866, -0.3067, -0.0089, -0.0063), (52.3451, -0.2840, -0.0061, -0.0293),
    (52.3688, -0.2381, -0.0002, -0.0377), (52.3985, -0.1602, -0.0091, -0.0439),
    (52.3986, -0.0778, -0.0328, -0.0481), (52.3808, -0.0915, -0.0417, -0.0544),
    (52.3454, -0.0365, -0.0654, -0.0585), (52.2683, -0.0410, -0.0922, -0.0773),
    (52.1677, -0.0087, -0.1425, -0.0626), (51.9486, 0.0424, -0.2817, -0.0351),
    (51.6111, 0.1130, -0.4269, -0.0370), (51.2620, 0.2033, -0.6076, -0.0262),
    (50.7589, 0.2866, -0.8297, 0.0055), (50.1258, 0.4110, -1.0460, 0.0289),
    (49.4813, 0.5582, -1.2206, 0.0689), (48.7319, 0.7995, -1.3240, 0.1591),
    (47.5556, 1.2959, -1.3174, 0.3015), (46.3746, 1.9315, -1.0561, 0.4225),
    (45.1118, 2.7760, -0.7414, 0.5811), (44.1815, 3.5815, -0.4949, 0.7042),
    (43.3127, 4.3049, -0.1657, 0.7476), (42.6962, 4.8985, 0.1068, 0.7388),
    (42.3096, 5.3314, 0.3022, 0.6883), (42.0529, 5.6455, 0.4471, 0.6148),
    (41.9044, 5.8845, 0.5476, 0.5476)
]

private func turnPair(_ row: (Double, Double, Double, Double), direction: Double = 1) -> [TransformContact] {
    boundaryPair(span: row.0, degrees: row.1 * direction, center: CGPoint(x: row.2, y: row.3 * direction))
}

@Test func radialTravelSuppressesLargeIncidentalAnglesWithoutAddingLatency() {
    for direction in [-1.0, 1.0] {
        var comparison = ClassifierComparison()
        for index in 0...20 {
            comparison.receive(mixedPinch(index, direction: direction), at: Double(index) * 0.008)
        }
        let old = comparison.traces.first { $0.variant.id == "independent" }!
        let current = comparison.traces.first { $0.variant.isCurrent }!
        #expect(old.decision == .rotation && old.committedClassifier == .geometryTilt)
        #expect(current.decision == .pinch && current.committedClassifier == .geometryPinch)
        #expect(current.decisionTime == old.decisionTime)
        let sample = current.inspection(at: current.decisionTime).sample!
        let tilt = sample.classifiers.first { $0.classifier == .geometryTilt }!
        #expect(tilt.blockers.contains { $0.contains("Angular versus radial travel") })
        #expect(current.samples.last?.classifiers.count == GestureClassifier.allCases.count && old.samples.last?.classifiers.count == 9)
    }
}

@Test func aDevelopingTurnRecoversFromRadialSetupOnTheHardwareClock() {
    for direction in [-1.0, 1.0] {
        var old = ContactTransform(configuration: .init(usesMotionBoundary: false))
        var current = ContactTransform()
        for (index, row) in developingTurn.enumerated() {
            let contacts = turnPair(row, direction: direction)
            let arrival = 10 + Double(index) * 0.00001
            let sensor = 100 + Double(index) * 0.015
            _ = old.receive(contacts, canBegin: true, at: arrival, sourceTimestamp: sensor)
            _ = current.receive(contacts, canBegin: true, at: arrival, sourceTimestamp: sensor)
            if index < developingTurn.count - 1 { #expect(current.intent == .undecided) }
            if index == 27 {
                let pinch = current.assessment.classifiers.first { $0.classifier == .geometryPinch }!
                #expect(pinch.blockers.contains { $0.contains("Developing turn ambiguity") })
            }
        }
        #expect(old.committedClassifier == .geometryTilt)
        #expect(current.intent == .rotation && current.committedClassifier == .developingTilt)
        #expect(abs(current.elapsed - 0.420) < 1e-9)
        #expect(current.assessment.classifiers.first { $0.classifier == .geometryTilt }?.isReady == false)
    }
}

@Test func anInterruptedDevelopingTurnMustEarnItsPersistenceAgain() {
    var transform = ContactTransform(configuration: .init(usesRelativeMotion: false))
    for (index, row) in developingTurn.dropLast().enumerated() {
        _ = transform.receive(turnPair(row), canBegin: true, at: Double(index) * 0.015)
    }
    #expect(transform.intent == .undecided)
    // Interrupt the turn before its recovery timer can complete.
    _ = transform.receive(boundaryPair(span: 42, degrees: 0), canBegin: true, at: 0.420)
    #expect(transform.intent == .undecided)
    let recovery = transform.assessment.classifiers.first { $0.classifier == .developingTilt }!
    #expect(!recovery.isReady && recovery.progress == 0)
    for time in [0.435, 0.450] {
        _ = transform.receive(boundaryPair(span: 42, degrees: 6), canBegin: true, at: time)
        #expect(transform.intent == .undecided)
    }
    _ = transform.receive(boundaryPair(span: 42, degrees: 6), canBegin: true, at: 0.465)
    #expect(transform.intent == .rotation && transform.committedClassifier == .developingTilt)
}

@Test func releasingThePairClearsTheRadialSetupHistory() {
    var transform = ContactTransform()
    for (index, row) in developingTurn.dropLast(3).enumerated() {
        _ = transform.receive(turnPair(row), canBegin: true, at: Double(index) * 0.015)
    }
    #expect(transform.assessment.classifiers.first { $0.classifier == .developingTilt }?.checks
        .first { $0.name == "Prior radial speed" }?.passed == true)
    _ = transform.receive([], canBegin: false, at: 1)
    _ = transform.receive(boundaryPair(span: 40, degrees: 0), canBegin: true, at: 1.1)
    _ = transform.receive(boundaryPair(span: 40, degrees: 3), canBegin: true, at: 1.108)
    let recovery = transform.assessment.classifiers.first { $0.classifier == .developingTilt }!
    #expect(recovery.checks.first { $0.name == "Prior radial speed" }?.passed == false)
    #expect(!recovery.isReady && transform.committedClassifier == nil)
}

@Test func jaggedEllipseAxesCannotChangeTheMotionBoundary() {
    var noAxis = ContactTransform(), jaggedAxis = ContactTransform()
    for index in 0...20 {
        let time = Double(index) * 0.008
        _ = noAxis.receive(mixedPinch(index), canBegin: true, at: time)
        _ = jaggedAxis.receive(mixedPinch(index, orientation: Double(index % 8) * .pi / 8), canBegin: true, at: time)
        #expect(noAxis.intent == jaggedAxis.intent && noAxis.committedClassifier == jaggedAxis.committedClassifier)
        #expect(noAxis.assessment.scores.pinch == jaggedAxis.assessment.scores.pinch)
        #expect(noAxis.assessment.scores.rotation == jaggedAxis.assessment.scores.rotation)
    }
    #expect(noAxis.intent == .pinch)
}
