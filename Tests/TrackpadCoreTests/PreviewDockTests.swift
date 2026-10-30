import CoreGraphics
import Testing
@testable import TrackpadCore

private let screen = CGSize(width: 1200, height: 800)
private let bounds = CGRect(x: 20, y: 20, width: 360, height: 220)

@Test func cornersUseSurfaceEdgesWithoutTransparentPadding() {
    for corner in [PreviewCorner.bottomLeft, .bottomRight, .topLeft, .topRight] {
        let origin = PreviewDock(corner: corner).origin(for: bounds, in: screen)
        let visible = bounds.offsetBy(dx: origin.x, dy: origin.y)
        #expect(corner.isLeft ? visible.minX == 24 : visible.maxX == 1176)
        #expect(corner.isTop ? visible.maxY == 768 : visible.minY == 24)
    }
}

@Test func tuckingMovesTheWholeSurfaceOutsideEitherEdge() {
    for corner in [PreviewCorner.bottomLeft, .bottomRight] {
        let dock = PreviewDock(corner: corner, tucked: true)
        let origin = dock.origin(for: bounds, in: screen)
        let visible = bounds.offsetBy(dx: origin.x, dy: origin.y)
        #expect(corner.isLeft ? visible.maxX < 0 : visible.minX > screen.width)
        let tab = dock.tab(in: screen, bounds: bounds)
        #expect(CGRect(origin: .zero, size: screen).contains(tab))
        #expect(tab.width == 24)
        #expect(tab.height == 94)
    }
}

@Test func slowReleaseSnapsToNearestCornerWithoutTucking() {
    let dock = PreviewDock.released(bounds: bounds, origin: CGPoint(x: 620, y: 470), velocity: .zero, screen: screen)
    #expect(dock == PreviewDock(corner: .topRight))
}

@Test func deliberateOutwardFlickTucksButVerticalFlickDoesNot() {
    let left = PreviewDock.released(bounds: bounds, origin: .zero, velocity: CGPoint(x: -900, y: 0), screen: screen)
    #expect(left == PreviewDock(corner: .bottomLeft, tucked: true))
    let up = PreviewDock.released(bounds: bounds, origin: CGPoint(x: 100, y: 250), velocity: CGPoint(x: 0, y: 1000), screen: screen)
    #expect(up == PreviewDock(corner: .topLeft))
}

@Test func weakerHorizontalAndVerticalThrowsReachTheOtherCorners() {
    for (center, velocity, corner) in [
        (CGPoint(x: 450, y: 250), CGPoint(x: 500, y: 0), PreviewCorner.bottomRight),
        (CGPoint(x: 750, y: 250), CGPoint(x: -500, y: 0), .bottomLeft),
        (CGPoint(x: 450, y: 250), CGPoint(x: 0, y: 500), .topLeft),
        (CGPoint(x: 450, y: 550), CGPoint(x: 0, y: -500), .bottomLeft)
    ] {
        let origin = CGPoint(x: center.x - bounds.midX, y: center.y - bounds.midY)
        #expect(PreviewDock.released(bounds: bounds, origin: origin, velocity: velocity, screen: screen) == PreviewDock(corner: corner))
    }
}

@Test func weakerDiagonalThrowsReachAllFourOppositeCorners() {
    for (center, velocity, corner) in [
        (CGPoint(x: 450, y: 250), CGPoint(x: 500, y: 500), PreviewCorner.topRight),
        (CGPoint(x: 750, y: 250), CGPoint(x: -500, y: 500), .topLeft),
        (CGPoint(x: 450, y: 550), CGPoint(x: 500, y: -500), .bottomRight),
        (CGPoint(x: 750, y: 550), CGPoint(x: -500, y: -500), .bottomLeft)
    ] {
        let origin = CGPoint(x: center.x - bounds.midX, y: center.y - bounds.midY)
        #expect(PreviewDock.released(bounds: bounds, origin: origin, velocity: velocity, screen: screen) == PreviewDock(corner: corner))
    }
}

@Test func fastCrossScreenThrowsNeverTuckAtTheFarEdge() {
    for (center, velocity, corner) in [
        (CGPoint(x: 450, y: 250), CGPoint(x: 4500, y: 0), PreviewCorner.bottomRight),
        (CGPoint(x: 750, y: 250), CGPoint(x: -4500, y: 0), .bottomLeft),
        (CGPoint(x: 450, y: 250), CGPoint(x: 4500, y: 2500), .topRight),
        (CGPoint(x: 750, y: 550), CGPoint(x: -4500, y: -2500), .bottomLeft)
    ] {
        let origin = CGPoint(x: center.x - bounds.midX, y: center.y - bounds.midY)
        #expect(PreviewDock.released(bounds: bounds, origin: origin, velocity: velocity, screen: screen) == PreviewDock(corner: corner))
    }
}

@Test func cornerProjectionDoesNotMakeOrdinaryReleasesOrEdgeTucksMoreSensitive() {
    let slow = PreviewDock.released(bounds: bounds, origin: CGPoint(x: 250, y: 120), velocity: CGPoint(x: 100, y: 100), screen: screen)
    #expect(slow == PreviewDock(corner: .bottomLeft))
    let awayFromEdge = PreviewDock.released(bounds: bounds, origin: CGPoint(x: 120, y: 120), velocity: CGPoint(x: -700, y: 0), screen: screen)
    #expect(awayFromEdge == PreviewDock(corner: .bottomLeft))
    let rightOutward = PreviewDock.released(bounds: bounds, origin: CGPoint(x: 800, y: 120), velocity: CGPoint(x: 900, y: 0), screen: screen)
    #expect(rightOutward == PreviewDock(corner: .bottomRight, tucked: true))
}

@Test func draggingAcrossTheMidpointBeforeAThrowCannotTuckTheOppositeEdge() {
    let right = PreviewDock.released(bounds: bounds, origin: CGPoint(x: 550, y: 120), velocity: CGPoint(x: 4500, y: 0),
                                    screen: screen, startingCorner: .bottomLeft)
    #expect(right == PreviewDock(corner: .bottomRight))
    let left = PreviewDock.released(bounds: bounds, origin: CGPoint(x: 250, y: 120), velocity: CGPoint(x: -4500, y: 0),
                                   screen: screen, startingCorner: .bottomRight)
    #expect(left == PreviewDock(corner: .bottomLeft))
}

@Test func draggingPastAnEdgeTucksEvenAtZeroVelocity() {
    let right = PreviewDock.released(bounds: bounds, origin: CGPoint(x: 950, y: 40), velocity: .zero, screen: screen)
    #expect(right == PreviewDock(corner: .bottomRight, tucked: true))
}

@Test func tabShouldersBlendIntoBothEdgesWithMirroredCutouts() {
    for corner in [PreviewCorner.bottomLeft, .bottomRight, .topLeft, .topRight] {
        let dock = PreviewDock(corner: corner, tucked: true)
        let frame = dock.tab(in: screen, bounds: bounds)
        let path = dock.tabPath(in: screen, bounds: bounds)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: corner.isLeft ? x : screen.width - x, y: frame.minY + y)
        }
        #expect(path.contains(point(0.25, frame.height / 2)))
        #expect(path.contains(point(0.25, -4)))
        #expect(path.contains(point(0.25, frame.height + 4)))
        #expect(!path.contains(point(12, -4)))
        #expect(!path.contains(point(12, frame.height + 4)))
        #expect(!path.contains(point(23.5, 0.5)))
        #expect(!path.contains(point(23.5, frame.height - 0.5)))
        #expect(path.contains(point(23.5, frame.height / 2)))
    }
}
