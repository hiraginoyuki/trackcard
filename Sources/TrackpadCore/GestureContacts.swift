import Foundation

/// A sensor path during one continuous lifetime, independent of anatomical
/// finger identity. Reusing a path ID after release creates a new lifetime.
public struct GestureContactIdentity: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var deviceID: UInt64
    public var pathID: Int32
    public var start: TimeInterval
    public var end: TimeInterval
    public var samples: Int

    public func isActive(at time: TimeInterval) -> Bool { time >= start && time < end }
}

public struct GestureContactOverlap: Codable, Sendable {
    public var first: String
    public var second: String
    public var frames: Int
}

public struct GestureContactIndex: Codable, Sendable {
    public var contacts: [GestureContactIdentity] = []
    public var overlaps: [GestureContactOverlap] = []

    /// Connected components of paths coexisting in at least two callback
    /// frames. A one-frame handoff does not join otherwise separate taps.
    public var automaticGroups: [[String]] {
        var components = contacts.map { [$0.id] }
        for overlap in overlaps where overlap.frames >= 2 {
            guard let first = components.firstIndex(where: { $0.contains(overlap.first) }),
                  let second = components.firstIndex(where: { $0.contains(overlap.second) }), first != second else { continue }
            components[first].append(contentsOf: components[second])
            components.remove(at: second)
        }
        return components.filter { $0.count > 1 }
    }
}

public struct GestureContactTracker: Sendable {
    public private(set) var index = GestureContactIndex()
    private var active: [UInt64: [Int32: Int]] = [:]
    private var occurrences: [UInt64: [Int32: Int]] = [:]
    private var pairs: [String: Int] = [:]
    private var lastSequence: [UInt64: UInt64] = [:]

    public init() {}

    public mutating func receive(_ frame: RecordedContactFrame) {
        guard frame.time.isFinite, frame.time >= 0, lastSequence[frame.deviceID] != frame.sequence else { return }
        lastSequence[frame.deviceID] = frame.sequence
        let visible = frame.contacts.filter { (1...4).contains($0.stage) }
        let ids = Set(visible.map(\.id))
        var paths = active[frame.deviceID] ?? [:]
        for (id, position) in paths where !ids.contains(id) {
            index.contacts[position].end = max(index.contacts[position].end, frame.time)
            paths.removeValue(forKey: id)
        }
        for contact in visible {
            if paths[contact.id] == nil {
                let occurrence = occurrences[frame.deviceID, default: [:]][contact.id, default: 0]
                occurrences[frame.deviceID, default: [:]][contact.id] = occurrence + 1
                paths[contact.id] = index.contacts.count
                index.contacts.append(GestureContactIdentity(id: "\(frame.deviceID):\(contact.id):\(occurrence)",
                    deviceID: frame.deviceID, pathID: contact.id, start: frame.time, end: frame.time, samples: 0))
            }
            let position = paths[contact.id]!
            index.contacts[position].end = max(index.contacts[position].end, frame.time)
            index.contacts[position].samples += 1
        }
        let current = paths.values.sorted().map { index.contacts[$0].id }
        for first in current.indices {
            for second in current.indices where second > first {
                let key = current[first] + "/" + current[second]
                if let pair = pairs[key] { index.overlaps[pair].frames += 1 }
                else {
                    pairs[key] = index.overlaps.count
                    index.overlaps.append(GestureContactOverlap(first: current[first], second: current[second], frames: 1))
                }
            }
        }
        active[frame.deviceID] = paths
    }

    public mutating func finish(at time: TimeInterval) {
        guard time.isFinite else { return }
        for paths in active.values {
            for position in paths.values { index.contacts[position].end = max(index.contacts[position].end, time) }
        }
        active.removeAll()
    }
}

/// Delivers frames against the recorded clock, seeding a clip with only the
/// latest state of each device. Equal-time frames retain callback order.
public struct GestureReplayCursor: Sendable {
    public let start: TimeInterval
    public let end: TimeInterval
    public var duration: TimeInterval { end - start }
    public private(set) var position: TimeInterval
    private let frames: [RecordedContactFrame]
    private var next = 0

    public init(frames: [RecordedContactFrame], start: TimeInterval = 0, end: TimeInterval) {
        let clipStart = max(0, start)
        let clipEnd = max(clipStart, end)
        self.start = clipStart
        self.end = clipEnd
        position = clipStart
        let ordered = frames.enumerated().filter { $0.element.time.isFinite && $0.element.time >= 0 }
            .sorted { $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time < $1.element.time }.map(\.element)
        var initial: [UInt64: Int] = [:]
        for (index, frame) in ordered.enumerated() where frame.time <= clipStart { initial[frame.deviceID] = index }
        self.frames = ordered.enumerated().compactMap { index, frame in
            guard frame.time <= clipEnd, frame.time > clipStart || initial[frame.deviceID] == index else { return nil }
            return frame
        }
    }

    public mutating func advance(to elapsed: TimeInterval) -> [RecordedContactFrame] {
        guard elapsed.isFinite else { return [] }
        position = min(end, max(position, start + max(0, elapsed)))
        let first = next
        while next < frames.count && frames[next].time <= position { next += 1 }
        return Array(frames[first..<next])
    }
}
