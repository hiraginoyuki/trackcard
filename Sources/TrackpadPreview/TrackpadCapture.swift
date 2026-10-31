import Foundation
import TrackpadBridge
import TrackpadCore

struct TrackpadDevice: Equatable {
    let id: UInt64
    let name: String
    let sizeMM: CGSize
    let builtIn: Bool
    let color: SurfaceColor?
}

struct SurfaceColor: Equatable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
}

struct Contact {
    let id: Int32
    let stage: UInt32
    let position: CGPoint
    let radiiMM: CGSize
    let angle: CGFloat
    var force: CGFloat = 0
    var velocity: CGPoint = .zero
    var proximity: CGFloat = 0
    var tilt: CGFloat = 0
    var density: CGFloat = 0
    var classification: UInt32 = 0
    var isTouching: Bool { stage == 3 || stage == 4 }
    var isVisible: Bool { (1...4).contains(stage) }
}

extension Contact {
    init(recorded: RecordedContact) {
        self.init(id: recorded.id, stage: recorded.stage, position: recorded.position,
                  radiiMM: recorded.radiiMM, angle: recorded.angle, force: recorded.force,
                  velocity: recorded.velocity, proximity: recorded.proximity, tilt: recorded.tilt,
                  density: recorded.density, classification: recorded.classification)
    }
}

struct ContactFrame {
    let sequence: UInt64
    let receivedAt: TimeInterval
    let contacts: [Contact]
    var sourceTimestamp: TimeInterval = 0
    var sourceFrame: UInt64 = 0
    var callbackAt: TimeInterval = 0
    var streamID: UInt64 = 0
}

@MainActor
final class TrackpadCapture {
    private let monitor: OpaquePointer
    private var sequences: [UInt64: UInt64] = [:]
    private var recognitionBuffer = [TPRecordedFrame](repeating: TPRecordedFrame(), count: Int(TP_RECOGNITION_CAPACITY))

    init() { monitor = TPMonitorCreate()! }

    var error: String? {
        let message = String(cString: TPMonitorError(monitor))
        return message.isEmpty ? nil : message
    }

    func refresh() -> [TrackpadDevice] {
        TPMonitorRefresh(monitor)
        var buffer = [TPDeviceInfo](repeating: TPDeviceInfo(), count: Int(TP_MAX_DEVICES))
        let count = TPMonitorCopyDevices(monitor, &buffer, Int32(buffer.count))
        let devices = buffer.prefix(Int(count)).map { info in
            var name = info.name
            let label = withUnsafeBytes(of: &name) { bytes in
                String(cString: bytes.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            return TrackpadDevice(
                id: info.id, name: label,
                sizeMM: CGSize(width: info.widthMM, height: info.heightMM), builtIn: info.builtIn,
                color: info.hasColor ? SurfaceColor(red: CGFloat(info.red), green: CGFloat(info.green), blue: CGFloat(info.blue)) : nil
            )
        }.sorted {
            if $0.builtIn != $1.builtIn { return $0.builtIn }
            return $0.id < $1.id
        }
        let ids = Set(devices.map(\.id))
        sequences = sequences.filter { ids.contains($0.key) }
        return Array(devices.prefix(2))
    }

    func frame(for deviceID: UInt64) -> ContactFrame? {
        var frame = TPFrame()
        guard TPMonitorCopyFrame(monitor, deviceID, &frame), sequences[deviceID] != frame.sequence else { return nil }
        sequences[deviceID] = frame.sequence
        return Self.decode(frame)
    }

    func setRecording(_ enabled: Bool) { TPMonitorSetRecording(monitor, enabled) }

    func recognitionFrames() -> (frames: [(UInt64, ContactFrame)], dropped: UInt64) {
        // One bounded snapshot per drain. New callbacks remain for the next tick.
        var dropped: UInt64 = 0
        let count = Int(TPMonitorCopyRecognitionFrames(monitor, &recognitionBuffer, Int32(recognitionBuffer.count), &dropped))
        return (recognitionBuffer.prefix(count).map { ($0.deviceID, Self.decode($0.frame)) }, dropped)
    }

    func recordedFrames() -> (frames: [(UInt64, ContactFrame)], dropped: UInt64) {
        var buffer = [TPRecordedFrame](repeating: TPRecordedFrame(), count: 64)
        var frames: [(UInt64, ContactFrame)] = []
        var dropped: UInt64 = 0
        while true {
            let count = Int(TPMonitorCopyRecordedFrames(monitor, &buffer, Int32(buffer.count), &dropped))
            frames.append(contentsOf: buffer.prefix(count).map { ($0.deviceID, Self.decode($0.frame)) })
            if count < buffer.count { break }
        }
        return (frames, dropped)
    }

    private static func decode(_ raw: TPFrame) -> ContactFrame {
        var frame = raw
        let count = Int(frame.count)
        let contacts = withUnsafeBytes(of: &frame.contacts) { bytes in
            bytes.bindMemory(to: TPContact.self).prefix(count).map {
                Contact(id: $0.id, stage: $0.stage, position: CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)),
                        radiiMM: CGSize(width: CGFloat($0.majorRadiusMM), height: CGFloat($0.minorRadiusMM)),
                        angle: CGFloat($0.angle), force: CGFloat($0.force),
                        velocity: CGPoint(x: CGFloat($0.velocityX), y: CGFloat($0.velocityY)),
                        proximity: CGFloat($0.proximity), tilt: CGFloat($0.tilt), density: CGFloat($0.density),
                        classification: $0.classification)
            }
        }
        return ContactFrame(sequence: frame.sequence, receivedAt: frame.receivedAt, contacts: contacts,
                            sourceTimestamp: frame.sourceTimestamp, sourceFrame: frame.sourceFrame,
                            callbackAt: frame.callbackAt, streamID: frame.streamID)
    }

    func close() { TPMonitorDestroy(monitor) }
}
