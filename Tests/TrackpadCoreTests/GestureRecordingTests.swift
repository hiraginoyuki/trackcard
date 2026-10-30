import Foundation
import CoreGraphics
import Testing
@testable import TrackpadCore

private let recordingDevices = [RecordedDevice(id: 1, name: "First", sizeMM: CGSize(width: 100, height: 80)),
                                RecordedDevice(id: 2, name: "Second", sizeMM: CGSize(width: 150, height: 100))]

@Test func rightClickRecordingsPreserveTheirLabelAndNativePressTiming() throws {
    var session = GestureRecordingSession(label: .rightClick, devices: recordingDevices, at: 0)
    session.receive(RecordedGestureEvent(kind: "Right Click", time: 0.01, phase: "began"))
    session.receive(RecordedGestureEvent(kind: "Right Click", time: 0.02, phase: "ended"))
    let attempt = session.finish(at: 0.03)
    let restored = try JSONDecoder().decode(GestureAttempt.self, from: JSONEncoder().encode(attempt))
    #expect(restored.label == .rightClick)
    #expect(restored.intervals.contains { $0.kind == "AppKit Right Click" && $0.start == 0.01 && $0.end == 0.02 })
}
private func sample(_ time: Double, device: UInt64 = 1, touching: Bool = true, angle: Double = 0) -> RecordedContactFrame {
    RecordedContactFrame(deviceID: device, sequence: UInt64(time * 1000), time: time, contacts: touching ? [
        RecordedContact(id: 1, stage: 4, position: CGPoint(x: 0.2, y: 0.4), radiiMM: CGSize(width: 6, height: 4), angle: 0),
        RecordedContact(id: 2, stage: 4, position: CGPoint(x: 0.2 + 0.4 * cos(angle), y: 0.4 + 0.5 * sin(angle)),
                        radiiMM: CGSize(width: 6, height: 4), angle: angle)
    ] : [])
}

@Test func contactsAndNativeGesturesOverlapOnOneTimeline() throws {
    var session = GestureRecordingSession(label: .swipe, devices: recordingDevices, at: 100)
    session.receive(sample(0))
    session.receive(RecordedGestureEvent(kind: "Scroll", time: 0.1, phase: "began", x: 10))
    session.receive(sample(0.2, device: 2))
    session.receive(RecordedGestureEvent(kind: "Scroll", time: 0.3, phase: "ended"))
    session.receive(sample(0.4, touching: false))
    let attempt = session.finish(at: 0.5)
    let first = try #require(attempt.intervals.first { $0.deviceID == 1 })
    let second = try #require(attempt.intervals.first { $0.deviceID == 2 })
    let scroll = try #require(attempt.intervals.first { $0.kind == "AppKit Scroll" })
    #expect(first.start == 0 && first.end == 0.4)
    #expect(second.start == 0.2 && second.end == 0.5)
    #expect(scroll.start == 0.1 && scroll.end == 0.3)
    #expect(attempt.intervals.allSatisfy { !$0.isActive })
    #expect(attempt.duration == 0.5 && attempt.frameCount == 3)
}

@Test func repeatedGesturesKeepSeparateIntervalsAndTheirIntendedLabel() {
    var session = GestureRecordingSession(label: .swipe, devices: recordingDevices, at: 0)
    session.receive(sample(0))
    session.receive(sample(0.1, angle: .pi / 8))
    session.receive(sample(0.15, angle: .pi / 8))
    session.receive(sample(0.199, angle: .pi / 8))
    session.receive(sample(0.2, touching: false))
    session.receive(sample(0.3))
    session.receive(sample(0.4, touching: false))
    let attempt = session.finish(at: 0.5)
    #expect(attempt.label == .swipe)
    #expect(attempt.intervals.filter { $0.kind == "Contacts" }.count == 2)
    #expect(attempt.intervals.contains { $0.kind == "Recognized Tilt" })
}

@Test func unphasedAppKitEventsExpireAndNeverMergeDistantAttempts() {
    var session = GestureRecordingSession(label: .tilt, devices: recordingDevices, at: 0)
    session.receive(RecordedGestureEvent(kind: "Tilt", time: 0.1, phase: "changed", value: 4))
    session.tick(at: 0.4)
    #expect(session.attempt.intervals[0].end == 0.1 && !session.attempt.intervals[0].isActive)
    session.receive(RecordedGestureEvent(kind: "Tilt", time: 0.5, phase: "changed", value: 5))
    #expect(session.attempt.intervals.count == 2)
}

@Test func recordingRoundTripPreservesFieldsNeededForHeuristics() throws {
    var frame = sample(0.2)
    frame.sourceTimestamp = 42.123
    frame.sourceFrame = 99
    frame.contacts[0].force = 0.7
    frame.contacts[0].velocity = CGPoint(x: 0.3, y: -0.4)
    frame.contacts[0].tilt = 0.2
    frame.contacts[0].classification = 5
    let decoded = try JSONDecoder().decode(RecordedContactFrame.self, from: JSONEncoder().encode(frame))
    #expect(decoded.sourceFrame == 99 && decoded.sourceTimestamp == 42.123)
    #expect(decoded.contacts[0].velocity.y == -0.4 && decoded.contacts[0].force == 0.7)
    #expect(decoded.contacts[0].tilt == 0.2 && decoded.contacts[0].classification == 5)
}

@Test func finishingPreservesDropCountsAndNewDeviceMetadata() throws {
    var session = GestureRecordingSession(label: .pinch, devices: [recordingDevices[0]], at: 0)
    session.updateDevices(recordingDevices)
    session.receive(sample(0, device: 2))
    session.tick(at: 0.3, droppedFrames: 8)
    session.tick(at: 0.4, droppedFrames: 3)
    let attempt = session.finish(at: 0.5)
    let decoded = try JSONDecoder().decode(GestureAttempt.self, from: JSONEncoder().encode(attempt))
    #expect(decoded.devices.count == 2 && decoded.droppedFrames == 8)
    #expect(decoded.intervals[0].end == 0.5 && !decoded.intervals[0].isActive)
}

@Test func sharedMovementIsRecordedByTheSameClassifierAndVersioned() throws {
    var session = GestureRecordingSession(label: .tilt, devices: recordingDevices, at: 0)
    session.receive(sample(0))
    var moved = sample(0.02)
    for index in moved.contacts.indices { moved.contacts[index].position.x += 0.05 }
    session.receive(moved)
    session.receive(sample(0.03, touching: false))
    let attempt = session.finish(at: 0.04)
    let interval = try #require(attempt.intervals.first { $0.kind == "Recognized Swipe" })
    #expect(interval.start == 0.02 && interval.end == 0.03 && !interval.isActive)
    #expect(attempt.recognizerVersion == ContactTransform.version && attempt.label == .tilt)
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(attempt)) as? [String: Any])
    json.removeValue(forKey: "recognizerVersion")
    let legacy = try JSONDecoder().decode(GestureAttempt.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(legacy.recognizerVersion == nil)
}
