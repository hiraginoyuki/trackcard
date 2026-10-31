import Foundation
import TrackpadCore

@MainActor
final class ClassifierTuningStore {
    static let shared = ClassifierTuningStore()
    private let defaults = UserDefaults.standard
    private var saved: [UInt64: TiltThresholds] = [:]
    private var drafts: [UInt64: TiltThresholds] = [:]

    func thresholds(for deviceID: UInt64) -> TiltThresholds {
        if let draft = drafts[deviceID] { return draft }
        if let saved = saved[deviceID] { return saved }
        let value = defaults.data(forKey: key(deviceID)).flatMap { try? JSONDecoder().decode(TiltThresholds.self, from: $0) } ?? .standard
        saved[deviceID] = value
        return value
    }

    func preview(_ thresholds: TiltThresholds, for deviceID: UInt64) { drafts[deviceID] = thresholds }
    func discardPreview(for deviceID: UInt64) { drafts.removeValue(forKey: deviceID) }

    func apply(_ thresholds: TiltThresholds, for deviceID: UInt64) throws {
        let data = try JSONEncoder().encode(thresholds)
        if thresholds == .standard { defaults.removeObject(forKey: key(deviceID)) }
        else { defaults.set(data, forKey: key(deviceID)) }
        saved[deviceID] = thresholds
        drafts.removeValue(forKey: deviceID)
    }

    func snapshot(for devices: [RecordedDevice]) -> [String: TiltThresholds] {
        Dictionary(uniqueKeysWithValues: devices.compactMap { device in
            let value = thresholds(for: device.id)
            return value == .standard ? nil : (String(device.id), value)
        })
    }

    private func key(_ deviceID: UInt64) -> String { "classifier.tilt.\(deviceID)" }
}
