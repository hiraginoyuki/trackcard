import CoreGraphics
import Foundation
import Testing
@testable import TrackpadCore

private func tuningPair(span: Double = 40, degrees: Double = 0) -> [TransformContact] {
    let angle = degrees * .pi / 180
    return [TransformContact(id: 1, positionMM: CGPoint(x: -span / 2 * cos(angle), y: -span / 2 * sin(angle))),
            TransformContact(id: 2, positionMM: CGPoint(x: span / 2 * cos(angle), y: span / 2 * sin(angle)))]
}

@Test func aDeviceCanFavorAMixedTurnWhileAnotherKeepsTheBaselineDecision() {
    var standard = ContactTransform()
    var tuned = ContactTransform(configuration: .init(tiltThresholds: .init(angularToRadialRatio: 0.4)))
    for time in [0.0, 0.06, 0.10, 0.14, 0.16, 0.18] {
        let contacts = time == 0 ? tuningPair() : tuningPair(span: 44, degrees: 2.5)
        _ = standard.receive(contacts, canBegin: true, at: time)
        _ = tuned.receive(contacts, canBegin: true, at: time)
    }
    #expect(standard.intent == .pinch && standard.committedClassifier == .geometryPinch)
    #expect(tuned.intent == .rotation && tuned.committedClassifier == .geometryTilt)
    #expect(tuned.assessment.classifiers.first { $0.classifier == .geometryTilt }?.checks.contains {
        $0.name == "Angular versus radial travel" && abs($0.threshold - 0.8) < 1e-9
    } == true)
}

@Test func retuningEndsTheCurrentTransformAndRequiresARelease() {
    var transform = ContactTransform()
    _ = transform.receive(tuningPair(), canBegin: true, at: 0)
    _ = transform.receive(tuningPair(span: 44), canBegin: true, at: 0.01)
    _ = transform.receive(tuningPair(span: 44), canBegin: true, at: 0.05)
    #expect(transform.intent == .pinch)
    let config = ContactTransform.Configuration(tiltThresholds: .init(angularToRadialRatio: 0.55))
    #expect(transform.reconfigure(config)?.phase == .ended)
    for time in [0.06, 0.10, 0.14] {
        #expect(transform.receive(tuningPair(degrees: 12), canBegin: true, at: time) == nil)
        #expect(transform.intent == .undecided && !transform.isTracking)
    }
    _ = transform.receive([], canBegin: true, at: 0.15)
    _ = transform.receive(tuningPair(), canBegin: true, at: 0.16)
    #expect(transform.isTracking && transform.configuration == config)
}

@Test func retuningCannotRemoveANativeClickVeto() {
    var transform = ContactTransform()
    _ = transform.receive(tuningPair(), canBegin: true, at: 0)
    _ = transform.interrupt()
    _ = transform.reconfigure(.init(tiltThresholds: .init(persistence: 0.008)))
    _ = transform.receive(tuningPair(degrees: 10), canBegin: true, at: 0.1)
    #expect(!transform.isTracking && transform.intent == .undecided)
}

@Test func aTunedComparisonPreservesEveryHistoricalConfigurationAndItsReleaseGate() {
    let thresholds = TiltThresholds(angularToRadialRatio: 0.55)
    let variants = ClassifierVariant.withTuning(thresholds)
    #expect(variants.filter(\.isCurrent).count == 1 && variants.last?.isCurrent == true)
    #expect(Array(variants.dropLast()).map(\.configuration) == ClassifierVariant.comparisons.map(\.configuration))
    var comparison = ClassifierComparison()
    comparison.receive(tuningPair(), at: 0)
    comparison.receiveRightClick()
    comparison.reconfigure(variants: variants)
    comparison.receive(tuningPair(degrees: 10), at: 0.01)
    #expect(!comparison.isCollecting)
    comparison.receive([], at: 0.02)
    comparison.receive(tuningPair(), at: 0.03)
    #expect(comparison.isCollecting && comparison.traces.allSatisfy { $0.samples.count == 1 })
    var idle = ClassifierComparison()
    idle.reconfigure(variants: variants)
    idle.receive(tuningPair(), at: 0)
    #expect(idle.isCollecting)
}

@Test func tuningIsRecordedPerDeviceAndOldRecordingsKeepTheirDefaults() throws {
    let thresholds = TiltThresholds(angularToRadialRatio: 0.4)
    let devices = [RecordedDevice(id: 1, name: "External", sizeMM: CGSize(width: 100, height: 100)),
                   RecordedDevice(id: 2, name: "Built-in Trackpad", sizeMM: CGSize(width: 100, height: 100))]
    var session = GestureRecordingSession(label: .tilt, devices: devices, at: 0, tiltThresholdsByDevice: ["1": thresholds])
    for time in [0.0, 0.06, 0.10, 0.14, 0.16, 0.18] {
        for device in devices {
            let contacts = (time == 0 ? tuningPair() : tuningPair(span: 44, degrees: 2.5)).map {
                RecordedContact(id: $0.id, stage: 4, position: CGPoint(x: $0.positionMM.x / 100, y: $0.positionMM.y / 100),
                                radiiMM: CGSize(width: 5, height: 3), angle: 0)
            }
            session.receive(RecordedContactFrame(deviceID: device.id, sequence: UInt64(time * 1000) + 1, time: time, contacts: contacts))
        }
    }
    let attempt = session.finish(at: 0.2)
    #expect(attempt.intervals.contains { $0.deviceID == 1 && $0.kind == "Recognized Tilt" })
    #expect(attempt.intervals.contains { $0.deviceID == 2 && $0.kind == "Recognized Pinch" })
    let data = try JSONEncoder().encode(attempt)
    #expect(try JSONDecoder().decode(GestureAttempt.self, from: data).tiltThresholdsByDevice == ["1": thresholds])
    var old = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    old.removeValue(forKey: "tiltThresholdsByDevice")
    #expect(try JSONDecoder().decode(GestureAttempt.self, from: JSONSerialization.data(withJSONObject: old)).tiltThresholdsByDevice == nil)
}

@Test func persistedThresholdsCannotBypassTheirInputBounds() throws {
    let data = Data(#"{"tangentialConfidence":-5,"angularToRadialRatio":-1,"persistence":-10}"#.utf8)
    let decoded = try JSONDecoder().decode(TiltThresholds.self, from: data)
    #expect(decoded == TiltThresholds(tangentialConfidence: 0.3, angularToRadialRatio: 0.2, persistence: 0.008))
    #expect(TiltThresholds(tangentialConfidence: .nan, angularToRadialRatio: .infinity, persistence: .nan) == .standard)
}

@Test func malformedTuningFramesAreRejectedBeforeIndexingContactArrays() throws {
    for fragment in [#""points":[[1]],"ids":[1]"#,
                     #""points":[[1,2]],"ids":[]"#,
                     #""points":[[1,2]],"radii":[[1]]"#] {
        let data = Data(("{\"arrival\":0,\"sensor\":0," + fragment + "}").utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ClassifierTuningDataset.Frame.self, from: data) }
    }
}
