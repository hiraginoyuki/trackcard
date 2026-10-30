import Foundation
import CoreGraphics
import Testing
@testable import TrackpadCore

private func preview(_ time: TimeInterval, x: Double, y: Double = 0.5,
                     scale: Double = 0.5, corner: PreviewCorner = .bottomLeft,
                     tucked: Bool = false, tab: Double = 0) -> RecordedPreviewState {
    RecordedPreviewState(time: time, center: CGPoint(x: x, y: y), scale: scale,
                         corner: corner, tucked: tucked, tabOpacity: tab)
}

@Test func previewReplayInterpolatesDisplayedMotionAtTheSessionClock() throws {
    let timeline = PreviewReplayTimeline([
        preview(1, x: 0.2, y: 0.3),
        preview(2, x: 0.8, y: 0.7, scale: 1, corner: .topRight, tucked: true, tab: 1)
    ])
    // A selected contact clip may begin between motion samples. Its first
    // position must use that point in the session, rather than restart motion.
    let state = try #require(timeline.state(at: 1.5))
    #expect(state.time == 1.5)
    #expect(abs(state.center.x - 0.5) < 0.000001 && abs(state.center.y - 0.5) < 0.000001)
    #expect(state.scale == 0.75 && state.tabOpacity == 0.5)
    #expect(state.corner == .bottomLeft && !state.tucked)
    let tucked = try #require(timeline.state(at: 2))
    #expect(tucked.corner == .topRight && tucked.tucked && tucked.tabOpacity == 1)
}

@Test func previewReplayHoldsTheBoundaryPositions() throws {
    let timeline = PreviewReplayTimeline([preview(1, x: 0.2), preview(2, x: 0.8)])
    #expect(try #require(timeline.state(at: 0)).center.x == 0.2)
    #expect(try #require(timeline.state(at: 20)).center.x == 0.8)
    let single = PreviewReplayTimeline([preview(1, x: 0.4, corner: .topLeft, tucked: true)])
    #expect(try #require(single.state(at: 0)).tucked)
    #expect(try #require(single.state(at: 20)).corner == .topLeft)
    #expect(PreviewReplayTimeline([]).state(at: 0) == nil)
}

@Test func previewReplayUsesTheLastStateAtDuplicateTimes() throws {
    let timeline = PreviewReplayTimeline([
        preview(2, x: 1), preview(1, x: 0.2), preview(1, x: 0.6), preview(0, x: 0)
    ])
    #expect(try #require(timeline.state(at: 1)).center.x == 0.6)
    #expect(abs(try #require(timeline.state(at: 1.5)).center.x - 0.8) < 0.000001)
    #expect(timeline.state(at: .nan) == nil && timeline.state(at: .infinity) == nil)
}

@Test func invalidPreviewSamplesDoNotBreakInterpolation() throws {
    let invalid = [preview(-1, x: 0), preview(.nan, x: 0), preview(0, x: .infinity),
                   preview(0, x: 0, y: .nan), preview(0, x: 0, scale: 0),
                   preview(0, x: 0, scale: .infinity), preview(0, x: 0, tab: .nan)]
    #expect(PreviewReplayTimeline(invalid).isEmpty)
    let timeline = PreviewReplayTimeline(invalid + [preview(0, x: 0.2), preview(1, x: 0.8)])
    #expect(abs(try #require(timeline.state(at: 0.5)).center.x - 0.5) < 0.000001)
}

@Test func previewRecordingPreservesTuckedPositionsOutsideTheDisplay() throws {
    let state = preview(0.25, x: -0.1, y: 0.9, scale: 0.75, corner: .topLeft, tucked: true, tab: 1)
    let decoded = try JSONDecoder().decode(RecordedPreviewState.self, from: JSONEncoder().encode(state))
    #expect(decoded.time == state.time && decoded.center == state.center && decoded.scale == state.scale)
    #expect(decoded.corner == .topLeft && decoded.tucked && decoded.tabOpacity == 1)
    #expect(try #require(PreviewReplayTimeline([decoded]).state(at: 1)).center.x == -0.1)
}
