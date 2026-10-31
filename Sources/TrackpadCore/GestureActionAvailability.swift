import Foundation

/// Available actions at the start of a contact pair. The interaction owner
/// supplies committed targets; animated presentation state is not evidence.
public struct GestureActionAvailability: Codable, Equatable, Sendable {
    public let canShrink: Bool
    public let canGrow: Bool
    public let canDecreaseOpacity: Bool
    public let canIncreaseOpacity: Bool

    public init(canShrink: Bool = true, canGrow: Bool = true,
                canDecreaseOpacity: Bool = true, canIncreaseOpacity: Bool = true) {
        self.canShrink = canShrink; self.canGrow = canGrow
        self.canDecreaseOpacity = canDecreaseOpacity; self.canIncreaseOpacity = canIncreaseOpacity
    }

    public init?(scale: Double, opacity: Double, minimumScale: Double,
                 maximumScale: Double, minimumOpacity: Double) {
        let epsilon = 1e-9
        guard [scale, opacity, minimumScale, maximumScale, minimumOpacity].allSatisfy(\.isFinite),
              minimumScale > 0, maximumScale > minimumScale, minimumOpacity >= 0, minimumOpacity < 1,
              scale >= minimumScale - epsilon, scale <= maximumScale + epsilon,
              opacity >= minimumOpacity - epsilon, opacity <= 1 + epsilon else { return nil }
        self.init(canShrink: scale > minimumScale + epsilon, canGrow: scale < maximumScale - epsilon,
                  canDecreaseOpacity: opacity > minimumOpacity + epsilon, canIncreaseOpacity: opacity < 1 - epsilon)
    }
}
