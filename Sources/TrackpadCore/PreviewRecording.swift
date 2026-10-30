import Foundation
import CoreGraphics

/// The displayed deck center is normalized to the selected display's visible
/// frame. Samples include presentation-layer motion during docking springs.
public struct RecordedPreviewState: Codable, Sendable {
    public var time: TimeInterval
    public var center: CGPoint
    public var scale: Double
    public var corner: PreviewCorner
    public var tucked: Bool
    public var tabOpacity: Double

    public init(time: TimeInterval, center: CGPoint, scale: Double, corner: PreviewCorner, tucked: Bool, tabOpacity: Double) {
        self.time = time; self.center = center; self.scale = scale
        self.corner = corner; self.tucked = tucked; self.tabOpacity = tabOpacity
    }
}

public struct PreviewReplayTimeline: Sendable {
    private let states: [RecordedPreviewState]
    public var isEmpty: Bool { states.isEmpty }

    public init(_ states: [RecordedPreviewState]) {
        self.states = states.enumerated().filter {
            let state = $0.element
            return state.time.isFinite && state.time >= 0 && state.center.x.isFinite && state.center.y.isFinite
                && state.scale.isFinite && state.scale > 0 && state.tabOpacity.isFinite
        }.sorted { $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time < $1.element.time }.map(\.element)
    }

    public func state(at time: TimeInterval) -> RecordedPreviewState? {
        guard time.isFinite, let first = states.first else { return nil }
        if time < first.time { return first }
        var lower = 0, upper = states.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if states[middle].time <= time { lower = middle + 1 } else { upper = middle }
        }
        let previous = states[max(0, lower - 1)]
        guard lower < states.count else { return previous }
        let next = states[lower]
        let fraction = (time - previous.time) / (next.time - previous.time)
        var result = previous
        result.time = time
        result.center = CGPoint(x: previous.center.x + (next.center.x - previous.center.x) * fraction,
                                y: previous.center.y + (next.center.y - previous.center.y) * fraction)
        result.scale += (next.scale - previous.scale) * fraction
        result.tabOpacity += (next.tabOpacity - previous.tabOpacity) * fraction
        return result
    }
}
