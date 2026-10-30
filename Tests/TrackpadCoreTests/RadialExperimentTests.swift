import Foundation
import CoreGraphics
import Testing
@testable import TrackpadCore

private let radialSize = CGSize(width: 120, height: 80)
private func radialFrame(_ time: Double, angle: Double = 0, span: Double = 40, center: CGPoint = CGPoint(x: 60, y: 40),
                         device: UInt64 = 1, paths: [Int32] = [1, 2]) -> RecordedContactFrame {
    let radians = angle * .pi / 180
    return RecordedContactFrame(deviceID: device, sequence: UInt64(max(0, time * 1000)), time: time, contacts: paths.enumerated().map { i, id in
        let sign = i == 0 ? -1.0 : 1.0
        return RecordedContact(id: id, stage: 4,
            position: CGPoint(x: (center.x + sign * span / 2 * cos(radians)) / radialSize.width,
                              y: (center.y + sign * span / 2 * sin(radians)) / radialSize.height),
            radiiMM: CGSize(width: 5, height: 3), angle: 0)
    })
}
private func radialConfig(_ target: Double = 3, task: RadialTask = .rotation, start: RadialStart = .immediate) -> RadialTrialConfiguration {
    RadialTrialConfiguration(caseID: "fixture", task: task, target: target, tolerance: task == .rotation ? 0.8 : 1, start: start)
}

@Test func radialPlansCoverBothDirectionsStartsSpansAndControlsInReproducibleOrder() {
    let balanced = RadialTrialPlan.make(.balanced, practice: false, seed: 42)
    #expect(balanced.count == 24)
    let rotations = balanced.filter { $0.task == .rotation }
    #expect(rotations.count == 16)
    for target in [-45.0, -20, -8, -3, 3, 8, 20, 45] {
        #expect(Set(rotations.filter { $0.target == target }.map(\.start)) == [.settled, .immediate])
    }
    #expect(Set(rotations.compactMap(\.spanMM)) == [25, 55])
    #expect(Set(rotations.map(\.pace)) == [.natural, .careful, .quick])
    #expect(balanced.filter { $0.task == .hold }.count == 2)
    #expect(balanced.filter { $0.task == .pinch }.count == 2)
    #expect(balanced.filter { $0.task == .translation }.count == 4)
    #expect(balanced.map(\.caseID) == RadialTrialPlan.make(.balanced, practice: false, seed: 42).map(\.caseID))
    #expect(balanced.map(\.caseID) != RadialTrialPlan.make(.balanced, practice: false, seed: 43).map(\.caseID))
    #expect(Set(balanced.map(\.blockID)).count == 1 && Set(balanced.map(\.id)).count == 24)
    #expect(balanced.map(\.number) == Array(1...24))
    #expect(RadialTrialPlan.make(.precision, practice: false, seed: 42).count == 32)
    let controls = RadialTrialPlan.make(.controls, practice: true, seed: 42)
    #expect(controls.count == 11 && controls.prefix(3).allSatisfy(\.practice))
    #expect(controls.dropFirst(3).allSatisfy { !$0.practice && $0.task != .rotation })
}

@Test func radialSettledCueRequiresFreshQuietSamplesAndIsNeverBackdated() throws {
    var engine = RadialTrialEngine(radialConfig(start: .settled))
    for i in 0...45 {
        engine.receive(radialFrame(Double(i) / 100), sizeMM: radialSize)
        engine.tick(at: Double(i) / 100)
    }
    #expect(engine.record.cue == nil)
    engine.tick(at: 1)
    #expect(engine.record.cue == nil, "Stale sensor samples cannot reveal a cue")
    engine.receive(radialFrame(1), sizeMM: radialSize)
    for i in 101...149 {
        engine.receive(radialFrame(Double(i) / 100), sizeMM: radialSize)
        engine.tick(at: Double(i) / 100 + 0.002)
    }
    let cue = try #require(engine.record.cue)
    #expect(cue.time >= 1.46 && cue.time > cue.sampleTime)
    #expect(cue.baselineDuration >= 0.45 && cue.initialSpeedMMPerSecond == 0)
    #expect(engine.takeEvents().filter { $0.kind == "cue" }.count == 1)
    var immediate = RadialTrialEngine(radialConfig())
    immediate.receive(radialFrame(0), sizeMM: radialSize)
    immediate.tick(at: 0.03)
    #expect(immediate.record.cue?.time == 0.03 && immediate.record.cue?.sampleTime == 0)
}

@Test func radialMovementAndWrongSpanResetPreparation() {
    var config = radialConfig(start: .settled); config.spanMM = 25
    var engine = RadialTrialEngine(config)
    for i in 0...60 {
        engine.receive(radialFrame(Double(i) / 100), sizeMM: radialSize)
        engine.tick(at: Double(i) / 100)
    }
    #expect(engine.record.cue == nil)
    for i in 61...100 {
        engine.receive(radialFrame(Double(i) / 100, angle: Double(i), span: 25), sizeMM: radialSize)
        engine.tick(at: Double(i) / 100)
    }
    #expect(engine.record.cue == nil)
}

private func radialHardwareFrame(_ sample: Int, angle: Double = 0, center: CGPoint = CGPoint(x: 60, y: 40)) -> RecordedContactFrame {
    // Two 15 ms hardware samples can arrive only 3 µs apart over Bluetooth.
    let arrival = sample == 0 ? 0 : ceil(Double(sample) / 2) * 0.03 + (sample.isMultiple(of: 2) ? 0.000003 : 0)
    var frame = radialFrame(arrival, angle: angle, center: center, device: 2)
    frame.sequence = UInt64(sample + 1)
    frame.sourceTimestamp = 1000 + Double(sample) * 0.015
    frame.sourceFrame = UInt64(sample + 1)
    return frame
}

@Test func radialBatchedHardwareFramesCanSettleOnSecondTrackpad() throws {
    var engine = RadialTrialEngine(radialConfig(start: .settled))
    for sample in 0...40 {
        let frame = radialHardwareFrame(sample, center: CGPoint(x: 60 + Double(sample) * 0.03, y: 40))
        engine.receive(frame, sizeMM: radialSize)
        engine.tick(at: frame.time + 0.001)
    }
    let cue = try #require(engine.record.cue)
    #expect(cue.deviceID == 2 && cue.baselineDuration >= 0.45)
    #expect(cue.time > cue.sampleTime, "The displayed cue remains on the rendering clock")
    #expect(abs(try #require(cue.initialSpeedMMPerSecond) - 2) < 1e-7)
    #expect(engine.record.result == nil)
}

@Test func radialBatchedHardwareFramesCanHoldATargetWithoutFalseRateSpikes() throws {
    var engine = RadialTrialEngine(radialConfig())
    let initial = radialHardwareFrame(0)
    engine.receive(initial, sizeMM: radialSize); engine.tick(at: 0)
    for sample in 1...40 {
        engine.receive(radialHardwareFrame(sample, angle: 3 + (sample.isMultiple(of: 2) ? 0.06 : -0.06)), sizeMM: radialSize)
    }
    let result = try #require(engine.record.result)
    #expect(result.outcome == .acquired && engine.record.cue?.deviceID == 2)
    #expect(try #require(result.final).absoluteError < 0.061)
}

@Test(arguments: [true, false]) func radialHardwareTimingPreservesArrivalAndSensorGapInterruptions(arrivalGap: Bool) {
    var engine = RadialTrialEngine(radialConfig())
    engine.receive(radialHardwareFrame(0), sizeMM: radialSize); engine.tick(at: 0)
    var frame = radialHardwareFrame(1)
    frame.time = arrivalGap ? 0.2 : 0.015
    frame.sourceTimestamp = 1000 + (arrivalGap ? 0.015 : 0.2)
    engine.receive(frame, sizeMM: radialSize)
    #expect(engine.record.result?.outcome == .interrupted)
}

@Test func radialHardwareTimingStillDetectsActualAbruptMovement() {
    var engine = RadialTrialEngine(radialConfig())
    engine.receive(radialHardwareFrame(0), sizeMM: radialSize); engine.tick(at: 0)
    engine.receive(radialHardwareFrame(1), sizeMM: radialSize)
    var jump = radialHardwareFrame(2, center: CGPoint(x: 68, y: 40))
    jump.sourceTimestamp = 1000.02
    engine.receive(jump, sizeMM: radialSize)
    #expect(engine.record.result?.outcome == .abruptMovement)
}

@Test func radialSpacingGuideUsesLivePhysicalPairAndClearsAfterLift() throws {
    var config = radialConfig(start: .settled); config.spanMM = 25
    var engine = RadialTrialEngine(config)
    engine.receive(radialFrame(0, angle: 60, span: 55), sizeMM: radialSize)
    #expect(engine.record.cue == nil && engine.deviceID == 1)
    #expect(abs(try #require(engine.currentSpan) - 55) < 1e-9)
    #expect(engine.currentPointsMM.count == 2)
    let points = engine.currentPointsMM
    #expect(abs(points[1].x - points[0].x - 27.5) < 1e-9)
    #expect(abs(points[1].y - points[0].y - 55 * sin(.pi / 3)) < 1e-9)
    engine.receive(radialFrame(0.01, paths: [1]), sizeMM: radialSize)
    #expect(engine.currentPointsMM.isEmpty && engine.currentSpan == nil && engine.deviceID == nil)
    engine.tick(at: 0.02)
    #expect(engine.record.cue == nil)
    for i in 2...51 {
        engine.receive(radialFrame(Double(i) / 100, span: 25 + config.spanToleranceMM), sizeMM: radialSize)
        engine.tick(at: Double(i) / 100)
    }
    #expect(engine.record.cue != nil, "Guide acceptance and cue preparation use the same span tolerance")
}

@Test func radialCursorCancellationBeforeCueIsSavedOnceAndRoundTrips() throws {
    var engine = RadialTrialEngine(radialConfig(start: .settled))
    engine.receive(radialFrame(0), sizeMM: radialSize)
    engine.finish(.cancelled, at: 0.1)
    engine.finish(.stopped, at: 0.2)
    engine.tick(at: 1)
    #expect(engine.phase == .finished && engine.record.cue == nil)
    #expect(engine.record.result?.outcome == .cancelled && engine.record.result?.endedAt == 0.1)
    #expect(engine.takeEvents().map(\.kind) == ["result"])
    let decoded = try JSONDecoder().decode(RadialTrialRecord.self, from: JSONEncoder().encode(engine.record))
    #expect(decoded.result?.outcome == .cancelled)
}

@Test func radialAbruptMovementSavesTheOffendingGeometryAndDistinctOutcome() throws {
    var engine = RadialTrialEngine(radialConfig())
    engine.receive(radialFrame(0), sizeMM: radialSize); engine.tick(at: 0)
    engine.receive(radialFrame(0.01), sizeMM: radialSize)
    engine.receive(radialFrame(0.02, center: CGPoint(x: 68, y: 40)), sizeMM: radialSize)
    let result = try #require(engine.record.result)
    #expect(engine.phase == .finished && result.outcome == .abruptMovement && result.endedAt == 0.02)
    #expect(abs(try #require(result.final).translation.x - 8) < 1e-9)
    #expect(engine.takeEvents().map(\.kind) == ["cue", "result"])
    engine.finish(.stopped, at: 0.03)
    #expect(engine.record.result?.outcome == .abruptMovement && engine.takeEvents().isEmpty)
    let decoded = try JSONDecoder().decode(RadialTrialRecord.self, from: JSONEncoder().encode(engine.record))
    #expect(decoded.result?.outcome == .abruptMovement)
}

@Test func radialAbruptMovementRequiresSpeedJumpAndMeaningfulDistance() {
    for (interval, distance) in [(0.01, 2.8), (0.002, 1.5), (0.07, 8.0)] {
        var engine = RadialTrialEngine(radialConfig())
        engine.receive(radialFrame(0), sizeMM: radialSize); engine.tick(at: 0)
        engine.receive(radialFrame(0.01), sizeMM: radialSize)
        engine.receive(radialFrame(0.01 + interval, center: CGPoint(x: 60 + distance, y: 40)), sizeMM: radialSize)
        #expect(engine.phase == .active, "Moderate speed, small jitter, and gaps with unknown speed cannot trigger a retry")
    }
    var engine = RadialTrialEngine(radialConfig())
    engine.receive(radialFrame(0), sizeMM: radialSize); engine.tick(at: 0)
    engine.receive(radialFrame(0.01, center: CGPoint(x: 65.8, y: 40)), sizeMM: radialSize)
    engine.receive(radialFrame(0.02, center: CGPoint(x: 72.3, y: 40)), sizeMM: radialSize)
    #expect(engine.phase == .active, "High speed without a sharp increase is not an abrupt jump")
}

@Test func radialAbruptMovementIgnoresPreparationAndAllowsQuickTargetedTurns() {
    var preparation = RadialTrialEngine(radialConfig(start: .settled))
    preparation.receive(radialFrame(0), sizeMM: radialSize)
    preparation.receive(radialFrame(0.01), sizeMM: radialSize)
    preparation.receive(radialFrame(0.02, center: CGPoint(x: 68, y: 40)), sizeMM: radialSize)
    #expect(preparation.record.result == nil && preparation.record.cue == nil)

    var quick = RadialTrialEngine(radialConfig(45))
    quick.receive(radialFrame(0, span: 55), sizeMM: radialSize); quick.tick(at: 0)
    for i in 1...50 {
        quick.receive(radialFrame(Double(i) / 100, angle: min(45, Double(i) * 4.5), span: 55), sizeMM: radialSize)
    }
    #expect(quick.record.result?.outcome == .acquired, "A 45° turn in 100 ms remains a valid fast gesture")
}

@Test func radialSmallAngleRequiresDwellAndPreservesPhysicalUnits() throws {
    var engine = RadialTrialEngine(radialConfig())
    engine.receive(radialFrame(0), sizeMM: radialSize); engine.tick(at: 0)
    engine.receive(radialFrame(0.01, angle: 3), sizeMM: radialSize)
    #expect(abs(try #require(engine.measurement).rotation - 3) < 1e-10)
    #expect(engine.phase == .active)
    for i in 2...38 { engine.receive(radialFrame(Double(i) / 100, angle: 3), sizeMM: radialSize) }
    let result = try #require(engine.record.result)
    #expect(result.outcome == .acquired)
    #expect(try #require(result.final).absoluteError < 1e-10)
    #expect(result.firstTargetTime == 0.01)
    #expect(try #require(result.settlingTime) >= 0.02)
    #expect(engine.takeEvents().map(\.kind) == ["cue", "result"])
}

@Test(arguments: [-1.0, 1.0]) func radialOvershootAndReactionAreSignedByTargetDirection(_ sign: Double) throws {
    var engine = RadialTrialEngine(radialConfig(3 * sign))
    engine.receive(radialFrame(0), sizeMM: radialSize); engine.tick(at: 0)
    engine.receive(radialFrame(0.01, angle: 5 * sign), sizeMM: radialSize)
    for i in 2...41 { engine.receive(radialFrame(Double(i) / 100, angle: 3 * sign), sizeMM: radialSize) }
    let result = try #require(engine.record.result)
    #expect(abs(result.peakOvershoot - 2) < 1e-9)
    #expect(result.reactionTime == 0.01 && result.outcome == .acquired)
}

@Test func radialContactIdentityLossLiftAndSensorGapsHaveDistinctOutcomes() {
    for (paths, expected) in [([Int32](), RadialOutcome.lifted), ([1, 3], .interrupted), ([1, 2, 3], .interrupted)] {
        var engine = RadialTrialEngine(radialConfig())
        engine.receive(radialFrame(0), sizeMM: radialSize); engine.tick(at: 0)
        engine.receive(radialFrame(0.01, device: 2, paths: []), sizeMM: radialSize)
        #expect(engine.phase == .active, "A second trackpad cannot end the trial")
        engine.receive(radialFrame(0.02, paths: paths), sizeMM: radialSize)
        #expect(engine.record.result?.outcome == expected)
    }
    var engine = RadialTrialEngine(radialConfig())
    engine.receive(radialFrame(0), sizeMM: radialSize); engine.tick(at: 0)
    engine.receive(radialFrame(0.2, angle: 3), sizeMM: radialSize)
    #expect(engine.record.result?.outcome == .interrupted)
}

@Test func radialTimeoutKeepsReceivingButDoesNotAwardAStaticWrongTarget() {
    var engine = RadialTrialEngine(radialConfig(45))
    engine.receive(radialFrame(0), sizeMM: radialSize); engine.tick(at: 0)
    for i in 1...1000 {
        engine.receive(radialFrame(Double(i) / 100), sizeMM: radialSize)
        engine.tick(at: Double(i) / 100)
    }
    #expect(engine.record.result?.outcome == .timedOut)
}

@Test func radialControlGeometryMeasuresPinchAndPerpendicularTranslationError() throws {
    var pinch = RadialTrialEngine(radialConfig(15, task: .pinch))
    pinch.receive(radialFrame(0), sizeMM: radialSize); pinch.tick(at: 0)
    pinch.receive(radialFrame(0.01, span: 46), sizeMM: radialSize)
    #expect(abs(try #require(pinch.measurement).value - 15) < 1e-9)
    var swipe = RadialTrialEngine(radialConfig(10, task: .translation))
    swipe.receive(radialFrame(0), sizeMM: radialSize); swipe.tick(at: 0)
    swipe.receive(radialFrame(0.01, center: CGPoint(x: 70, y: 45)), sizeMM: radialSize)
    let sample = try #require(swipe.measurement)
    #expect(abs(sample.value - 10) < 1e-9 && abs(sample.absoluteError - 5) < 1e-9)
    #expect(swipe.holdProgress == 0, "Projected distance alone cannot count as hitting a 2D target")
    var hold = RadialTrialEngine(radialConfig(0, task: .hold))
    hold.receive(radialFrame(0), sizeMM: radialSize); hold.tick(at: 0)
    hold.receive(radialFrame(0.01, center: CGPoint(x: 61.2, y: 40)), sizeMM: radialSize)
    #expect(try #require(hold.measurement).absoluteError > 1)
}

@Test func radialReplayMatchesLiveGeometryAcrossAngleWrapAndKeepsOutcomeImmutable() throws {
    var engine = RadialTrialEngine(radialConfig(20))
    engine.receive(radialFrame(0, angle: 170), sizeMM: radialSize); engine.tick(at: 0)
    var replay = RadialTrialPlayback(engine.record)
    for i in 1...40 {
        let frame = radialFrame(Double(i) / 100, angle: -170)
        engine.receive(frame, sizeMM: radialSize); replay.receive(frame, sizeMM: radialSize)
    }
    #expect(abs(try #require(replay.measurement).rotation - 20) < 1e-8)
    #expect(abs(try #require(engine.measurement).rotation - 20) < 1e-8)
    #expect(engine.record.result?.outcome == .acquired)
}

@Test func radialMetadataRoundTripsAndOldAttemptsRemainReadable() throws {
    var session = GestureRecordingSession(label: .tilt, devices: [], at: 0)
    let old = try JSONEncoder().encode(session.attempt)
    #expect(try JSONDecoder().decode(GestureAttempt.self, from: old).radialTrial == nil)
    var engine = RadialTrialEngine(radialConfig())
    engine.receive(radialFrame(0), sizeMM: radialSize); engine.tick(at: 0)
    engine.finish(.stopped, at: 0.1)
    session.updateRadialTrial(engine.record)
    let decoded = try JSONDecoder().decode(GestureAttempt.self, from: JSONEncoder().encode(session.finish(at: 0.2)))
    #expect(decoded.radialTrial?.configuration.target == 3)
    #expect(decoded.radialTrial?.result?.outcome == .stopped)
    #expect(decoded.radialTrial?.cue?.time == 0)
}
