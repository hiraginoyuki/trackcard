import Foundation
import CoreGraphics

public enum TrackpadLayout: Equatable, Sendable {
    case stacked
    case sideBySide
}

/// A monotonic-clock state machine, independent of rendering and capture.
public struct TrackpadActivity: Sendable {
    public static let sharedUseInterval: TimeInterval = 0.5
    public static let exclusiveUseInterval: TimeInterval = 2

    public private(set) var deviceIDs: [UInt64] = []
    public private(set) var frontID: UInt64?
    public private(set) var layout: TrackpadLayout = .stacked
    private var touching: Set<UInt64> = []
    private var lastInput: [UInt64: TimeInterval] = [:]
    private var exclusiveID: UInt64?
    private var exclusiveSince: TimeInterval?

    public init() {}

    public mutating func setDevices(_ ids: [UInt64]) {
        deviceIDs = Array(ids.prefix(2))
        let connected = Set(deviceIDs)
        touching.formIntersection(connected)
        lastInput = lastInput.filter { connected.contains($0.key) }
        if frontID.map({ !connected.contains($0) }) ?? true { frontID = deviceIDs.first }
        if connected.count < 2 {
            layout = .stacked
            exclusiveID = nil
            exclusiveSince = nil
        }
    }

    public mutating func receive(deviceID: UInt64, hasContact: Bool, at time: TimeInterval) {
        guard deviceIDs.contains(deviceID), time.isFinite else { return }
        if hasContact {
            if !touching.contains(deviceID) { frontID = deviceID }
            touching.insert(deviceID)
            lastInput[deviceID] = time
        } else {
            touching.remove(deviceID)
        }
        evaluate(at: time)
    }

    public mutating func evaluate(at time: TimeInterval) {
        guard deviceIDs.count == 2, time.isFinite else { return }
        let bothTouching = touching.count == 2
        let bothRecent = deviceIDs.allSatisfy {
            guard let last = lastInput[$0] else { return false }
            return time >= last && time - last <= Self.sharedUseInterval
        }
        if bothTouching || bothRecent { layout = .sideBySide }
        guard layout == .sideBySide else { return }
        if bothTouching {
            exclusiveID = nil
            exclusiveSince = nil
        } else if let only = touching.first ?? exclusiveID ?? frontID {
            if exclusiveID != only {
                exclusiveID = only
                exclusiveSince = time
            }
            // Keep the timer running after the last finger lifts, so the
            // display-frame clock can restack without waiting for another tap.
            if let since = exclusiveSince, time - since >= Self.exclusiveUseInterval {
                layout = .stacked
                frontID = only
                exclusiveID = nil
                exclusiveSince = nil
            }
        }
    }
}

public enum PhysicalGeometry {
    public static func pointsPerMillimeter(screenPoints: CGSize, screenMM: CGSize) -> CGSize {
        guard screenMM.width > 100, screenMM.height > 60,
              screenMM.width.isFinite, screenMM.height.isFinite else {
            return CGSize(width: 72 / 25.4, height: 72 / 25.4)
        }
        return CGSize(width: screenPoints.width / screenMM.width,
                      height: screenPoints.height / screenMM.height)
    }

    public static func surfaceSize(millimeters: CGSize, pointsPerMM: CGSize, calibration: Double = 1) -> CGSize {
        CGSize(width: millimeters.width * pointsPerMM.width * calibration,
               height: millimeters.height * pointsPerMM.height * calibration)
    }
}
