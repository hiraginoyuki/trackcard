import CoreGraphics
import Foundation
import Testing
@testable import TrackpadCore

private func replayExample(times: [Double], spans: [Double], turns: [Double], arrivalStep: Double? = nil,
                           release: Bool = true, preparation: Bool = false, offset: Double = 0) throws -> ClassifierTuningDataset.Example {
    var frames: [[String: Any]] = []
    if preparation { frames.append(["arrival": 0.5, "sensor": 999.985, "points": [[20.0, 20.0]], "ids": [1]]) }
    for index in times.indices {
        let angle = turns[index] * .pi / 180, radius = spans[index] / 2
        frames.append(["arrival": arrivalStep.map { 1 + offset + Double(index) * $0 } ?? (1 + offset + times[index]),
                       "sensor": 1000 + offset + times[index], "ids": [1, 2],
                       "points": [[50 - radius * cos(angle), 50 - radius * sin(angle)],
                                  [50 + radius * cos(angle), 50 + radius * sin(angle)]]])
    }
    if release {
        frames.append(["arrival": arrivalStep.map { 1 + offset + Double(times.count) * $0 } ?? (1.015 + offset + (times.last ?? 0)),
                       "sensor": 1000.015 + offset + (times.last ?? 0), "points": [], "ids": []])
    }
    let object: [String: Any] = ["ref": "g1", "session": "s1", "label": "Tilt", "deviceID": "1", "builtIn": false, "frames": frames]
    return try JSONDecoder().decode(ClassifierTuningDataset.Example.self, from: JSONSerialization.data(withJSONObject: object))
}

@Test func replayShowsLaterTiltReadinessWithoutRewritingThePinchDecision() throws {
    let times = (0...22).map { Double($0) * 0.015 }
    let spans = times.map { 40 + min($0, 0.12) * 80 }
    let turns = times.map { max(0, $0 - 0.12) * 180 }
    let example = try replayExample(times: times, spans: spans, turns: turns)
    let replay = TuningGestureReplay(example: example, thresholds: .standard)
    let decision = try #require(replay.previewDecision)
    let tilt = try #require(replay.firstTiltReady)
    #expect(decision.intent == .pinch)
    #expect(tilt.time > decision.time)
    #expect(replay.samples[tilt.sampleIndex].preview.intent == .pinch)
    #expect(replay.samples[tilt.sampleIndex].preview.checks.contains { $0.classifier.intent == .rotation && $0.isReady })
    #expect(replay.samples[decision.sampleIndex].turnDegrees == 0)
}

@Test func replayUsesSensorTimeAndNeverShowsTheNextFrameWhileScrubbing() throws {
    let times = (0...12).map { Double($0) * 0.015 }
    let example = try replayExample(times: times, spans: times.map { 40 + $0 * 80 }, turns: times.map { _ in 0 }, arrivalStep: 0.001)
    let replay = TuningGestureReplay(example: example, thresholds: .standard)
    var recognizer = ContactTransform()
    var decisionTime: Double?
    for frame in example.frames {
        _ = recognizer.receive(frame.contacts, canBegin: true, at: frame.arrival, sourceTimestamp: frame.sensor)
        if decisionTime == nil && recognizer.intent != .undecided { decisionTime = recognizer.elapsed }
    }
    #expect(abs(try #require(replay.previewDecision?.time) - #require(decisionTime)) < 1e-9)
    #expect(replay.index(at: 0.014) == 0)
    #expect(replay.index(at: 0.016) == 1)
    #expect(replay.index(at: -.infinity) == 0)
    #expect(replay.index(at: .infinity) == replay.samples.count - 1)
    #expect(replay.samples.last?.preview.checks.isEmpty == true)
}

@Test func replayRetainsPreparationAndStartsPairTimeAtZero() throws {
    let example = try replayExample(times: [0, 0.015, 0.03], spans: [40, 41, 42], turns: [0, 0, 0], preparation: true)
    let replay = TuningGestureReplay(example: example, thresholds: .standard)
    #expect(replay.startTime < 0)
    #expect(replay.samples[1].time == 0)
    #expect(replay.samples[0].contacts.count == 1)
    #expect(replay.samples[0].segment != replay.samples[1].segment)
    #expect(replay.samples.last?.segment != replay.samples[1].segment)
}

@Test func replayMatchesBaselineAndTunedDecisionsWhileKeepingRuleChecks() throws {
    let times = [0.0, 0.06, 0.10, 0.14, 0.16, 0.18]
    let example = try replayExample(times: times, spans: [40, 44, 44, 44, 44, 44], turns: [0, 2.5, 2.5, 2.5, 2.5, 2.5])
    let replay = TuningGestureReplay(example: example, thresholds: .init(angularToRadialRatio: 0.4))
    #expect(replay.baselineDecision?.intent == .pinch)
    #expect(replay.previewDecision?.intent == .rotation)
    let index = try #require(replay.previewDecision?.sampleIndex)
    #expect(replay.samples[index].baseline.checks.contains { $0.classifier == .geometryTilt && !$0.isReady })
    #expect(replay.samples[index].preview.checks.contains { $0.classifier == .geometryTilt && $0.isReady })
    #expect(abs(try #require(replay.samples[index].spacingChange) - 4) < 1e-9)
    #expect(abs(try #require(replay.samples[index].turnDegrees) - 2.5) < 1e-9)
}

@Test func anEmptyReplayHasNoInventedDecisionOrFrame() throws {
    let example = try replayExample(times: [], spans: [], turns: [], release: false)
    let replay = TuningGestureReplay(example: example, thresholds: .standard)
    #expect(replay.index(at: 0) == nil)
    #expect(replay.baselineDecision == nil && replay.previewDecision == nil && replay.firstTiltReady == nil)
}

@Test func replayCanCompareAgainstTheUsersSavedTiltSettings() throws {
    let times = [0.0, 0.06, 0.10, 0.14, 0.16, 0.18]
    let example = try replayExample(times: times, spans: [40, 44, 44, 44, 44, 44], turns: [0, 2.5, 2.5, 2.5, 2.5, 2.5])
    let saved = TiltThresholds(angularToRadialRatio: 0.4)
    let replay = TuningGestureReplay(example: example, thresholds: .standard, baselineThresholds: saved)
    #expect(replay.baselineDecision?.intent == .rotation)
    #expect(replay.previewDecision?.intent == .pinch)
    let index = try #require(replay.baselineDecision?.sampleIndex)
    #expect(replay.samples[index].baseline.checks.contains { $0.classifier == .geometryTilt && $0.isReady })
    #expect(!replay.samples[index].preview.checks.contains { $0.classifier == .geometryTilt && $0.isReady })
}

@Test func laterContactPairsCannotSupplyEvidenceForAnEarlierPinch() throws {
    let times = (0...10).map { Double($0) * 0.015 }
    let first = try replayExample(times: times, spans: times.map { 40 + $0 * 80 }, turns: times.map { _ in 0 })
    let second = try replayExample(times: times, spans: times.map { _ in 40 }, turns: times.map { $0 * 180 }, offset: 0.3)
    let combined = ClassifierTuningDataset.Example(ref: "g2", session: "s1", label: "Tilt", deviceID: "1", builtIn: false,
        frames: first.frames + second.frames)
    let replay = TuningGestureReplay(example: combined, thresholds: .standard)
    #expect(replay.previewDecision?.intent == .pinch)
    #expect(replay.firstTiltReady == nil)
    #expect(replay.samples.contains { $0.preview.checks.contains { $0.classifier.intent == .rotation && $0.isReady } })
}

@Test func replayDistinguishesRecordingTimeFromTheRecognizedContactPairClock() throws {
    let first = try replayExample(times: [0, 0.015], spans: [40, 40], turns: [0, 0])
    let times = (0...10).map { Double($0) * 0.015 }
    let second = try replayExample(times: times, spans: times.map { _ in 40 }, turns: times.map { $0 * 180 }, offset: 0.3)
    let combined = ClassifierTuningDataset.Example(ref: "g2", session: "s1", label: "Tilt", deviceID: "1", builtIn: false,
        frames: first.frames + second.frames)
    let replay = TuningGestureReplay(example: combined, thresholds: .standard)
    let event = try #require(replay.previewDecision)
    #expect(abs(event.time - event.elapsed - 0.3) < 1e-7)
    #expect(replay.firstTiltReady?.segment == event.segment)
}
