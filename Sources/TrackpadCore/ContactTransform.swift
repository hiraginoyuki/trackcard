import Foundation
import CoreGraphics

public struct TransformContact: Sendable {
    public let id: Int32
    public let positionMM: CGPoint
    public let orientation: Double?
    public let radiiMM: CGSize?
    public let force: Double?
    public init(id: Int32, positionMM: CGPoint, orientation: Double? = nil, radiiMM: CGSize? = nil,
                force: Double? = nil) {
        self.id = id
        self.positionMM = positionMM
        self.orientation = orientation; self.radiiMM = radiiMM
        self.force = force
    }
}
