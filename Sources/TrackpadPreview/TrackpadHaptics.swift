import AppKit
import Darwin
import TrackpadCore

/// Uses a low-amplitude actuator pulse for fine ticks. Availability is checked
/// at runtime, like contact capture; no system haptic preferences are changed.
@MainActor
final class TrackpadHaptics {
    private typealias Create = @convention(c) (UInt64) -> UnsafeMutableRawPointer?
    private typealias Open = @convention(c) (UnsafeMutableRawPointer, UInt32) -> Int32
    private typealias Close = @convention(c) (UnsafeMutableRawPointer) -> Int32
    private typealias Actuate = @convention(c) (UnsafeMutableRawPointer, Int32, UInt32, Float, Float) -> Int32
    private let library: UnsafeMutableRawPointer
    private let create: Create
    private let open: Open
    private let closeActuator: Close
    private let actuate: Actuate
    private var actuator: UnsafeMutableRawPointer?
    private var deviceID: UInt64?
    private var failedDeviceID: UInt64?

    init?() {
        guard let library = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY) else { return nil }
        guard let create = dlsym(library, "MTActuatorCreateFromDeviceID"),
              let open = dlsym(library, "MTActuatorOpen"),
              let close = dlsym(library, "MTActuatorClose"),
              let actuate = dlsym(library, "MTActuatorActuate") else { dlclose(library); return nil }
        self.library = library
        self.create = unsafeBitCast(create, to: Create.self)
        self.open = unsafeBitCast(open, to: Open.self)
        closeActuator = unsafeBitCast(close, to: Close.self)
        self.actuate = unsafeBitCast(actuate, to: Actuate.self)
    }

    @discardableResult
    func pulse(deviceID: UInt64?, amplitude: Double) -> Bool {
        guard let deviceID, amplitude.isFinite, amplitude > 0, failedDeviceID != deviceID else { return false }
        if self.deviceID != deviceID {
            close()
            guard let created = create(deviceID) else { failedDeviceID = deviceID; return false }
            guard open(created, 0) == 0 else {
                Unmanaged<AnyObject>.fromOpaque(created).release()
                failedDeviceID = deviceID
                return false
            }
            self.deviceID = deviceID
            actuator = created
        }
        guard let actuator else { return false }
        // Waveform 15 is the alignment pulse. The fourth argument scales its
        // amplitude; zero is a legacy sentinel, so never send zero through.
        let result = actuate(actuator, 15, 0, Float(min(0.2, amplitude)), 1)
        if result != 0 { close(); failedDeviceID = deviceID }
        return result == 0
    }

    func close() {
        if let actuator {
            _ = closeActuator(actuator)
            Unmanaged<AnyObject>.fromOpaque(actuator).release()
        }
        actuator = nil; deviceID = nil
    }
}
