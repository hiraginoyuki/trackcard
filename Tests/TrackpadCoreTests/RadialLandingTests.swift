import CoreGraphics
import Foundation
import Testing
@testable import TrackpadCore

private let size = CGSize(width: 120, height: 80)
private func frame(_ time: Double, angle: Double = 0, span: Double = 40, device: UInt64 = 2,
                   paths: [Int32] = [1, 2]) -> RecordedContactFrame {
    let radians = angle * .pi / 180
    return RecordedContactFrame(deviceID: device, sequence: UInt64(max(0, time * 1000)), time: time, contacts: paths.enumerated().map { index, id in
        let sign = index == 0 ? -1.0 : 1.0
        return RecordedContact(id: id, stage: 4,
            position: CGPoint(x: (60 + sign * span / 2 * cos(radians)) / size.width,
                              y: (40 + sign * span / 2 * sin(radians)) / size.height),
            radiiMM: CGSize(width: 5, height: 3), angle: 0)
    })
}
private func configuration() -> RadialTrialConfiguration {
    var config = RadialTrialConfiguration(caseID: "v2/fixture", task: .rotation, target: 3, tolerance: 0.8,
                                         start: .immediate, spanMM: 40)
    config.landingStyle = .staggered
    return config
}
private func prepared() -> RadialTrialEngine {
    var engine = RadialTrialEngine(configuration())
    for index in 0...50 {
        let time = Double(index) / 100
        engine.receive(frame(time), sizeMM: size); engine.tick(at: time)
    }
    return engine
}
private func awaitingLanding() -> RadialTrialEngine {
    var engine = prepared()
    engine.receive(frame(0.51, paths: []), sizeMM: size); engine.tick(at: 0.52)
    return engine
}

@Test func newPlansVersionAndCrossLandingStylesSpansAndDirections() {
    #expect(RadialPreset.current == [.landing, .landingPrecision, .landingControls])
    for preset in RadialPreset.current {
        let plan = RadialTrialPlan.make(preset, practice: false, seed: 42)
        #expect(plan.count == (preset == .landingControls ? 16 : 32))
        #expect(plan.allSatisfy { $0.protocolVersion == 2 && $0.start == .immediate && $0.caseID.hasPrefix("v2/") })
        #expect(plan.allSatisfy { RadialTrialRecord($0).schemaVersion == 2 && $0.preset == preset.rawValue })
        #expect(Set(plan.map(\.blockID)).count == 1 && Set(plan.map(\.id)).count == plan.count)
        #expect(plan.map(\.caseID) == RadialTrialPlan.make(preset, practice: false, seed: 42).map(\.caseID))
        #expect(plan.map(\.caseID) != RadialTrialPlan.make(preset, practice: false, seed: 43).map(\.caseID))
        if preset != .landingControls {
            let magnitudes: [Double] = preset == .landingPrecision ? [2, 4, 8, 15] : [3, 8, 20, 45]
            for target in magnitudes.flatMap({ [-$0, $0] }) {
                for span in [25.0, 55.0] {
                    #expect(Set(plan.filter { $0.target == target && $0.spanMM == span }.compactMap(\.landingStyle)) == [.together, .staggered])
                }
            }
        } else {
            #expect(plan.filter { $0.task == .hold }.count == 4)
            #expect(plan.filter { $0.task == .pinch }.count == 4)
            #expect(plan.filter { $0.task == .translation }.count == 8)
        }
        let practice = RadialTrialPlan.make(preset, practice: true, seed: 42)
        #expect(practice.count == plan.count + 3 && practice.prefix(3).allSatisfy(\.practice))
        #expect(practice.allSatisfy { $0.protocolVersion == 2 })
    }
    #expect([RadialPreset.balanced, .precision, .controls].allSatisfy { $0.isDeprecated })
}

@Test func newProtocolRequiresFullLiftAndRevealsBeforeNewPair() throws {
    var engine = prepared()
    #expect(engine.phase == .awaitingLift && engine.record.cue == nil)
    #expect(engine.takeEvents().map(\.kind) == ["prepared"])
    engine.receive(frame(0.51, paths: [1]), sizeMM: size); engine.tick(at: 0.51)
    engine.receive(frame(0.52, device: 1, paths: []), sizeMM: size); engine.tick(at: 0.52)
    #expect(engine.phase == .awaitingLift && engine.record.preparation?.releasedAt == nil)
    engine.receive(frame(0.53, paths: []), sizeMM: size)
    engine.tick(at: 0.54)
    #expect(engine.phase == .landing && engine.record.cue == nil && engine.currentPointsMM.isEmpty)
    #expect(engine.record.preparation?.releasedAt == 0.53 && engine.record.preparation?.targetTime == 0.54)
    engine.receive(frame(0.56, angle: 25, span: 42, paths: [7, 8]), sizeMM: size)
    let cue = try #require(engine.record.cue)
    #expect(engine.phase == .active && cue.paths == [7, 8] && cue.time == 0.54 && cue.sampleTime == 0.56)
    #expect(cue.baselineDuration == 0 && cue.initialSpeedMMPerSecond == nil)
    #expect(engine.record.preparation?.pairTime == 0.56 && engine.record.preparation?.firstContactTime == 0.56)
    #expect(abs(hypot(cue.pointsMM[1].x - cue.pointsMM[0].x, cue.pointsMM[1].y - cue.pointsMM[0].y) - 42) < 1e-9)
    for index in 57...100 {
        engine.receive(frame(Double(index) / 100, angle: 28, span: 42, paths: [7, 8]), sizeMM: size)
    }
    #expect(engine.record.result?.outcome == .acquired)
    #expect(abs(try #require(engine.record.result?.final?.rotation) - 3) < 1e-8)
    #expect(engine.takeEvents().map(\.kind) == ["released", "target", "cue", "result"])
}

@Test func earlyRelandingMustReleaseAgainBeforeTargetIsDisplayed() {
    var engine = prepared()
    engine.receive(frame(0.51, paths: []), sizeMM: size)
    engine.receive(frame(0.52), sizeMM: size); engine.tick(at: 0.53)
    #expect(engine.phase == .awaitingLift && engine.record.cue == nil && engine.record.preparation?.targetTime == nil)
    engine.receive(frame(0.54, paths: []), sizeMM: size); engine.tick(at: 0.55)
    #expect(engine.phase == .landing)
}

@Test func landingAllowsBriefSingleContactThenMeasuresWithoutSettling() {
    var engine = awaitingLanding()
    engine.receive(frame(0.54, paths: [5]), sizeMM: size)
    engine.tick(at: 0.60)
    #expect(engine.phase == .landing && engine.record.result == nil)
    engine.receive(frame(0.62, angle: 10, paths: [5, 6]), sizeMM: size)
    #expect(engine.phase == .active && engine.record.cue?.sampleTime == 0.62)
    #expect(engine.record.preparation?.firstContactTime == 0.54)
    engine.receive(frame(0.63, angle: 13, paths: [5, 6]), sizeMM: size)
    #expect(abs((engine.measurement?.rotation ?? 0) - 3) < 1e-8)
}

@Test(arguments: [5.0, 9.99, 10.0])
func closeLandingNeverSilentlyRestartsGapAdjustment(span: Double) throws {
    var engine = awaitingLanding()
    engine.receive(frame(0.54, span: span, paths: [5, 6]), sizeMM: size)
    #expect(engine.phase == (span < 10 ? .finished : .active))
    #expect(engine.record.result?.outcome == (span < 10 ? .invalidLanding : nil))
    #expect(engine.record.preparation?.targetTime == 0.52)
    if span < 10 {
        engine.receive(frame(0.55, paths: [5, 6]), sizeMM: size)
        engine.tick(at: 1.1)
        #expect(engine.phase == .finished && engine.record.cue == nil)
        let saved = try JSONDecoder().decode(RadialTrialRecord.self, from: JSONEncoder().encode(engine.record))
        #expect(saved.result?.outcome == .invalidLanding)
    }
}

@Test func duplicateLandingContactsFinishInsteadOfRequestingAnotherLift() {
    var engine = awaitingLanding()
    engine.receive(frame(0.54, paths: [5, 5]), sizeMM: size)
    #expect(engine.phase == .finished && engine.record.result?.outcome == .interrupted)
    #expect(engine.record.cue == nil)
}

@Test(arguments: [true, false]) func aSingleContactCannotWaitPast100msForItsPartner(tick: Bool) {
    var engine = awaitingLanding()
    engine.receive(frame(0.54, paths: [5]), sizeMM: size)
    if tick { engine.tick(at: 0.641) }
    else { engine.receive(frame(0.641, paths: [5, 6]), sizeMM: size) }
    #expect(engine.record.result?.outcome == .incompleteLanding && engine.record.cue == nil)
}

@Test func newMetadataAndLegacyRecordsRoundTripWithoutRewritingTheirProtocol() throws {
    var engine = awaitingLanding()
    engine.receive(frame(0.54), sizeMM: size)
    let current = try JSONDecoder().decode(RadialTrialRecord.self, from: JSONEncoder().encode(engine.record))
    #expect(current.schemaVersion == 2 && current.preparation?.pairTime == 0.54 && current.configuration.landingStyle == .staggered)
    var oldConfig = configuration(); oldConfig.landingStyle = nil
    let old = try JSONDecoder().decode(RadialTrialRecord.self, from: JSONEncoder().encode(RadialTrialRecord(oldConfig)))
    #expect(old.schemaVersion == 1 && old.preparation == nil && old.configuration.protocolTitle == "V1 · Deprecated")
    var playback = RadialTrialPlayback(current)
    playback.receive(frame(0.53, angle: 50), sizeMM: size)
    #expect(playback.measurement == nil)
    playback.receive(frame(0.55, angle: 3), sizeMM: size)
    #expect(abs((playback.measurement?.rotation ?? 0) - 3) < 1e-8)
}

@Test func aLighterHighSpeedJumpRequestsRetryOnlyWithTwoContacts() {
    var config = configuration(); config.landingStyle = nil
    for count in [1, 2, 3] {
        var engine = RadialTrialEngine(config)
        engine.receive(frame(0), sizeMM: size); engine.tick(at: 0)
        engine.receive(frame(0.01), sizeMM: size)
        var jump = frame(0.02, paths: Array(1...Int32(count)))
        jump.contacts = jump.contacts.map { contact in var moved = contact; moved.position.x += 3.5 / size.width; return moved }
        engine.receive(jump, sizeMM: size)
        #expect((engine.record.result?.outcome == .abruptMovement) == (count == 2))
    }
}

@Test(arguments: [RadialContinuationGate.Action.advance, .retry])
func continuationNeedsReleaseAndFreshTwoFingerChord(action: RadialContinuationGate.Action) {
    var gate = RadialContinuationGate(action: action, deviceID: 2, after: 1)
    gate.receive(deviceID: 2, time: 0.9, count: 0)
    gate.receive(deviceID: 1, time: 1.01, count: 0)
    gate.receive(deviceID: 2, time: 1.02, count: 2)
    #expect(gate.decision(at: 1.03) == .wait && gate.releasedAt == nil)
    gate.receive(deviceID: 2, time: 1.04, count: 0)
    gate.receive(deviceID: 2, time: 1.03, count: 2)
    #expect(gate.decision(at: 1.05) == .wait)
    gate.receive(deviceID: 2, time: 1.06, count: 1)
    let deferred = gate.deferCursorMovement(deviceID: 2, at: 1.07)
    #expect(deferred)
    #expect(gate.decision(at: 1.12) == .wait)
    gate.receive(deviceID: 2, time: 1.14, count: 2)
    gate.receive(deviceID: 2, time: 1.18, count: 2)
    #expect(gate.decision(at: 1.19) == .start, "A timely chord survives later samples and brief landing cursor motion")
}

@Test func pendingCursorMotionCancelsAfter100msEvenWithoutAnotherMouseEvent() {
    var gate = RadialContinuationGate(action: .retry, deviceID: 2, after: 1)
    gate.receive(deviceID: 2, time: 1.01, count: 0)
    gate.receive(deviceID: 2, time: 1.02, count: 1)
    let deferred = gate.deferCursorMovement(deviceID: 2, at: 1.03)
    #expect(deferred)
    #expect(gate.decision(at: 1.121) == .cancel)
    gate.receive(deviceID: 2, time: 1.13, count: 2)
    #expect(gate.decision(at: 1.14) == .cancel)
}

@Test func lateOrExtraContactsRequireAnotherFullRelease() {
    for extra in [false, true] {
        var gate = RadialContinuationGate(action: .retry, deviceID: 2, after: 1)
        gate.receive(deviceID: 2, time: 1.01, count: 0)
        gate.receive(deviceID: 2, time: 1.02, count: extra ? 3 : 1)
        gate.receive(deviceID: 2, time: 1.2, count: 2)
        #expect(gate.decision(at: 1.21) == .wait)
        gate.receive(deviceID: 2, time: 1.22, count: 0)
        gate.receive(deviceID: 2, time: 1.23, count: 2)
        #expect(gate.decision(at: 1.24) == .start)
    }
}

@Test(arguments: [0.0, 0.000001])
func secondContactDeadlineIncludesExactly100ms(lateness: Double) {
    let window = RadialTrialConfiguration.secondContactWindow
    var engine = awaitingLanding()
    let first = 0.57
    engine.receive(frame(first, paths: [5]), sizeMM: size)
    engine.tick(at: first + window)
    #expect(engine.record.result == nil)
    engine.receive(frame(first + window + lateness, paths: [5, 6]), sizeMM: size)
    #expect(engine.phase == (lateness == 0 ? .active : .finished))
    #expect(engine.record.result?.outcome == (lateness == 0 ? nil : .incompleteLanding))

    var gate = RadialContinuationGate(action: .retry, deviceID: 2, after: 1)
    gate.receive(deviceID: 2, time: 1.01, count: 0)
    gate.receive(deviceID: 2, time: 1.02, count: 1)
    let deferred = gate.deferCursorMovement(deviceID: 2, at: 1.02 + window)
    #expect(deferred)
    #expect(gate.decision(at: 1.02 + window) == .wait)
    let pairTime = 1.02 + window + lateness
    gate.receive(deviceID: 2, time: pairTime, count: 2)
    #expect(gate.decision(at: pairTime) == (lateness == 0 ? .start : .cancel))
}
