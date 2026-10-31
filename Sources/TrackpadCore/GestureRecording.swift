import Foundation
import CoreGraphics

public enum GestureLabel: String, Codable, CaseIterable, Sendable {
    case swipe = "Swipe", pinch = "Pinch", tilt = "Tilt", none = "None", rightClick = "Right Click"
}

public struct RecordedDevice: Codable, Sendable {
    public var id: UInt64
    public var name: String
    public var sizeMM: CGSize
    public init(id: UInt64, name: String, sizeMM: CGSize) { self.id = id; self.name = name; self.sizeMM = sizeMM }
}

public struct RecordedContact: Codable, Sendable {
    public var id: Int32
    public var stage: UInt32
    public var position: CGPoint
    public var radiiMM: CGSize
    public var angle: Double
    public var force: Double = 0
    public var velocity: CGPoint = .zero
    public var proximity: Double = 0
    public var tilt: Double = 0
    public var density: Double = 0
    public var classification: UInt32 = 0
    public init(id: Int32, stage: UInt32, position: CGPoint, radiiMM: CGSize, angle: Double) {
        self.id = id; self.stage = stage; self.position = position; self.radiiMM = radiiMM; self.angle = angle
    }
}

public struct RecordedContactFrame: Codable, Sendable {
    public var deviceID: UInt64
    public var sequence: UInt64
    public var time: TimeInterval
    public var sourceTimestamp: TimeInterval
    public var sourceFrame: UInt64
    public var contacts: [RecordedContact]
    public var pointerOverPreview: Bool?
    public var actionAvailability: GestureActionAvailability?
    /// Host receipt before waiting on the bridge lock, relative to recording start.
    public var callbackTime: TimeInterval?
    public init(deviceID: UInt64, sequence: UInt64, time: TimeInterval, sourceTimestamp: TimeInterval = 0,
                sourceFrame: UInt64 = 0, contacts: [RecordedContact], pointerOverPreview: Bool? = nil,
                actionAvailability: GestureActionAvailability? = nil) {
        self.deviceID = deviceID; self.sequence = sequence; self.time = time
        self.sourceTimestamp = sourceTimestamp; self.sourceFrame = sourceFrame; self.contacts = contacts
        self.pointerOverPreview = pointerOverPreview
        self.actionAvailability = actionAvailability
    }
}

public struct RecordedGestureEvent: Codable, Sendable {
    public var kind: String
    public var time: TimeInterval
    public var phase: String
    public var x: Double
    public var y: Double
    public var value: Double
    public init(kind: String, time: TimeInterval, phase: String, x: Double = 0, y: Double = 0, value: Double = 0) {
        self.kind = kind; self.time = time; self.phase = phase; self.x = x; self.y = y; self.value = value
    }
}

public struct GestureInterval: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var kind: String
    public var deviceID: UInt64?
    public var start: TimeInterval
    public var end: TimeInterval
    public var samples: Int = 0
    public var isActive = true
}

public struct GestureAttempt: Codable, Identifiable, Sendable {
    public var schemaVersion = 1
    public var recognizerVersion: String? = ContactTransform.version
    public var deliveryVersion: String? = RecognitionDelivery.version
    public var tiltThresholdsByDevice: [String: TiltThresholds]?
    public var id = UUID()
    public var label: GestureLabel
    public var startedAt = Date()
    public var duration: TimeInterval = 0
    public var devices: [RecordedDevice]
    public var frameCount = 0
    public var droppedFrames: UInt64 = 0
    public var intervals: [GestureInterval] = []
    public var contactIndex: GestureContactIndex?
    public var radialTrial: RadialTrialRecord?
}

/// Each source owns its own intervals. Native events, contacts from both
/// devices and recognizer output can overlap without forcing exclusivity.
public struct GestureRecordingSession: Sendable {
    public private(set) var attempt: GestureAttempt
    public let startedUptime: TimeInterval
    private var active: [String: Int] = [:]
    private var transforms: [UInt64: ContactTransform] = [:]
    private var contacts = GestureContactTracker()

    public init(label: GestureLabel, devices: [RecordedDevice], at time: TimeInterval,
                tiltThresholdsByDevice: [String: TiltThresholds] = [:]) {
        attempt = GestureAttempt(label: label, devices: devices)
        attempt.tiltThresholdsByDevice = tiltThresholdsByDevice.isEmpty ? nil : tiltThresholdsByDevice
        attempt.contactIndex = contacts.index
        startedUptime = time
    }

    public mutating func receive(_ frame: RecordedContactFrame) {
        guard frame.time.isFinite, frame.time >= 0 else { return }
        contacts.receive(frame)
        attempt.contactIndex = contacts.index
        attempt.frameCount += 1
        attempt.duration = max(attempt.duration, frame.time)
        let touching = frame.contacts.filter { $0.stage == 3 || $0.stage == 4 }
        observe(key: "contacts.\(frame.deviceID)", kind: "Contacts", deviceID: frame.deviceID,
                time: frame.time, ending: touching.isEmpty)
        guard let device = attempt.devices.first(where: { $0.id == frame.deviceID }) else { return }
        var transform = transforms[frame.deviceID] ?? ContactTransform(configuration: .init(
            tiltThresholds: attempt.tiltThresholdsByDevice?[String(frame.deviceID)] ?? .standard))
        let previousIntent = transform.intent
        let update = transform.receive(touching.map {
            TransformContact(id: $0.id, positionMM: CGPoint(x: $0.position.x * device.sizeMM.width,
                                                          y: $0.position.y * device.sizeMM.height), orientation: Double($0.angle), radiiMM: $0.radiiMM, force: Double($0.force))
        }, canBegin: true, at: frame.time, sourceTimestamp: frame.sourceTimestamp, pointerOverTarget: frame.pointerOverPreview,
           actionAvailability: frame.actionAvailability)
        transforms[frame.deviceID] = transform
        if transform.intent == .movement || previousIntent == .movement {
            observe(key: "recognized.\(frame.deviceID)", kind: "Recognized Swipe", deviceID: frame.deviceID,
                    time: frame.time, ending: transform.intent != .movement)
        } else if let update {
            let kind = update.kind == .magnify ? "Recognized Pinch" : "Recognized Tilt"
            observe(key: "recognized.\(frame.deviceID)", kind: kind, deviceID: frame.deviceID,
                    time: frame.time, ending: update.phase == .ended)
        }
    }

    public mutating func receive(_ event: RecordedGestureEvent) {
        guard event.time.isFinite, event.time >= 0 else { return }
        observe(key: "native.\(event.kind)", kind: "AppKit \(event.kind)", deviceID: nil, time: event.time,
                ending: event.phase == "ended" || event.phase == "cancelled", separateAfterGap: true)
        attempt.duration = max(attempt.duration, event.time)
    }

    public mutating func updateDevices(_ devices: [RecordedDevice]) {
        for device in devices where !attempt.devices.contains(where: { $0.id == device.id }) { attempt.devices.append(device) }
    }

    public mutating func updateRadialTrial(_ trial: RadialTrialRecord) { attempt.radialTrial = trial }

    public mutating func tick(at time: TimeInterval, droppedFrames: UInt64 = 0) {
        guard time.isFinite else { return }
        attempt.duration = max(attempt.duration, time)
        attempt.droppedFrames = max(attempt.droppedFrames, droppedFrames)
        for key in Array(active.keys) where key.hasPrefix("native.") {
            if let index = active[key], time - attempt.intervals[index].end > 0.25 {
                attempt.intervals[index].isActive = false
                active.removeValue(forKey: key)
            }
        }
    }

    public mutating func finish(at time: TimeInterval) -> GestureAttempt {
        tick(at: time)
        contacts.finish(at: time)
        attempt.contactIndex = contacts.index
        for index in active.values {
            attempt.intervals[index].end = max(attempt.intervals[index].end, time)
            attempt.intervals[index].isActive = false
        }
        active.removeAll()
        return attempt
    }

    private mutating func observe(key: String, kind: String, deviceID: UInt64?, time: TimeInterval,
                                  ending: Bool, separateAfterGap: Bool = false) {
        if let index = active[key], separateAfterGap && time - attempt.intervals[index].end > 0.25 {
            attempt.intervals[index].isActive = false
            active.removeValue(forKey: key)
        }
        if let index = active[key] {
            attempt.intervals[index].end = max(time, attempt.intervals[index].end)
            attempt.intervals[index].samples += 1
            if ending { attempt.intervals[index].isActive = false; active.removeValue(forKey: key) }
        } else if !ending {
            active[key] = attempt.intervals.count
            attempt.intervals.append(GestureInterval(kind: kind, deviceID: deviceID, start: time, end: time, samples: 1))
        }
    }
}
