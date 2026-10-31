import Foundation

/// A device-specific adjustment to the ordinary Tilt paths. Decisive paths,
/// native-click vetoes, and the held-pointer prior retain their existing rules.
public struct TiltThresholds: Codable, Equatable, Sendable {
    public static let standard = Self()
    public let tangentialConfidence: Double
    public let angularToRadialRatio: Double
    public let persistence: TimeInterval

    public init(tangentialConfidence: Double = 0.7, angularToRadialRatio: Double = 0.7,
                persistence: TimeInterval = 0.024) {
        self.tangentialConfidence = Self.bounded(tangentialConfidence, to: 0.3...0.85, fallback: 0.7)
        self.angularToRadialRatio = Self.bounded(angularToRadialRatio, to: 0.2...1, fallback: 0.7)
        self.persistence = Self.bounded(persistence, to: 0.008...0.04, fallback: 0.024)
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(tangentialConfidence: try values.decode(Double.self, forKey: .tangentialConfidence),
                  angularToRadialRatio: try values.decode(Double.self, forKey: .angularToRadialRatio),
                  persistence: try values.decode(TimeInterval.self, forKey: .persistence))
    }

    private static func bounded(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }
}
