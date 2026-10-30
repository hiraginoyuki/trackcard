import Foundation
import CoreGraphics

public enum PreviewCorner: String, Codable, Sendable {
    case bottomLeft, bottomRight, topLeft, topRight
    public var isLeft: Bool { self == .bottomLeft || self == .topLeft }
    public var isTop: Bool { self == .topLeft || self == .topRight }
}

public struct PreviewDock: Equatable, Sendable {
    public var corner: PreviewCorner
    public var tucked: Bool
    public init(corner: PreviewCorner = .bottomLeft, tucked: Bool = false) {
        self.corner = corner
        self.tucked = tucked
    }

    /// Work with visible surfaces, excluding the transparent animation reserve.
    public func origin(for bounds: CGRect, in screen: CGSize, inset: CGFloat = 24) -> CGPoint {
        let x: CGFloat
        if tucked { x = corner.isLeft ? -bounds.maxX - 8 : screen.width - bounds.minX + 8 }
        else { x = corner.isLeft ? inset - bounds.minX : screen.width - inset - bounds.maxX }
        let y = corner.isTop ? screen.height - max(32, inset) - bounds.maxY : inset - bounds.minY
        return CGPoint(x: x, y: y)
    }

    /// A projected release distinguishes a deliberate edge flick from corner docking.
    public static func released(bounds: CGRect, origin: CGPoint, velocity: CGPoint, screen: CGSize,
                                startingCorner: PreviewCorner? = nil) -> PreviewDock {
        let center = CGPoint(x: bounds.midX + origin.x, y: bounds.midY + origin.y)
        // A longer projection lowers the release speed needed to cross each
        // screen midpoint, including both midpoints on a diagonal throw.
        let projected = CGPoint(x: center.x + velocity.x * 0.32, y: center.y + velocity.y * 0.32)
        let left = projected.x < screen.width / 2
        let top = projected.y > screen.height / 2
        let corner: PreviewCorner = top ? (left ? .topLeft : .topRight) : (left ? .bottomLeft : .bottomRight)
        let beyondLeft = origin.x + bounds.minX < -bounds.width * 0.35
        let beyondRight = origin.x + bounds.maxX > screen.width + bounds.width * 0.35
        // Keep tuck sensitivity independent of corner selection. A throw
        // across the screen must land visibly, even if it projects past the
        // far edge; outward flicks only tuck on the drag's starting side.
        let edgeProjection = center.x + velocity.x * 0.18
        let startsOnLeft = startingCorner?.isLeft ?? (center.x < screen.width / 2)
        let flickLeft = startsOnLeft && velocity.x < -650 && edgeProjection - bounds.width / 2 < 0
        let flickRight = !startsOnLeft && velocity.x > 650 && edgeProjection + bounds.width / 2 > screen.width
        return PreviewDock(corner: corner, tucked: left ? beyondLeft || flickLeft : beyondRight || flickRight)
    }

    public func tab(in screen: CGSize, bounds: CGRect) -> CGRect {
        let height = min(94, max(48, bounds.height))
        let y = min(max(8, origin(for: bounds, in: screen).y + bounds.midY - height / 2), max(8, screen.height - height - 8))
        return CGRect(x: corner.isLeft ? 0 : screen.width - 24, y: y, width: 24, height: height)
    }

    public func tabPath(in screen: CGSize, bounds: CGRect) -> CGPath {
        let frame = tab(in: screen, bounds: bounds)
        let path = CGMutablePath()
        // Concave shoulders blend into the screen edge; the exposed corners
        // stay convex. Mirror the same outline for the opposite screen edge.
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: corner.isLeft ? x : screen.width - x, y: frame.minY + y)
        }
        let w = frame.width, h = frame.height, r: CGFloat = 9
        path.move(to: point(0, -r))
        path.addQuadCurve(to: point(r, 0), control: point(0, 0))
        path.addLine(to: point(w - r, 0))
        path.addQuadCurve(to: point(w, r), control: point(w, 0))
        path.addLine(to: point(w, h - r))
        path.addQuadCurve(to: point(w - r, h), control: point(w, h))
        path.addLine(to: point(r, h))
        path.addQuadCurve(to: point(0, h + r), control: point(0, h))
        path.closeSubpath()
        return path
    }
}
