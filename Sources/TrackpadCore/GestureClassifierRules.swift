import Foundation

/// A measured condition, kept with each score so diagnostics can name the
/// actual limiting input instead of inferring a cause from aggregate curves.
public struct GestureClassifierCheck: Sendable {
    public enum Comparison: String, Sendable { case atLeast = "≥", atMost = "≤", below = "<" }
    public let name: String
    public let value: Double
    public let comparison: Comparison
    public let threshold: Double
    public let unit: String

    public var passed: Bool {
        guard value.isFinite && threshold.isFinite else { return false }
        switch comparison {
        case .atLeast: return value >= threshold
        case .atMost: return value <= threshold
        case .below: return value < threshold
        }
    }

    var support: Double {
        guard value.isFinite && threshold.isFinite else { return 0 }
        if passed { return 1 }
        switch comparison {
        case .atLeast: return threshold > 0 ? min(1, max(0, value / threshold)) : 0
        case .atMost, .below: return value > 0 ? min(1, max(0, threshold / value)) : 0
        }
    }

    public var explanation: String {
        String(format: "%@: %.3g (needs %@ %.3g%@)", name, value, comparison.rawValue, threshold, unit.isEmpty ? "" : " \(unit)")
    }

    static func minimum(_ name: String, _ value: Double, _ threshold: Double, _ unit: String = "") -> Self {
        Self(name: name, value: value, comparison: .atLeast, threshold: threshold, unit: unit)
    }
    static func maximum(_ name: String, _ value: Double, _ threshold: Double, _ unit: String = "") -> Self {
        Self(name: name, value: value, comparison: .atMost, threshold: threshold, unit: unit)
    }
    static func gate(_ name: String, _ enabled: Bool) -> Self { minimum(name, enabled ? 1 : 0, 1) }
}

/// Shared measurements only. Classifiers read this immutable frame and own
/// their rules/timers; no classifier consumes a sibling's confidence.
struct GestureMeasurements: Sendable {
    private static let geometryPinchLogSpacing = log(1.08)
    private static let geometryTiltDegrees = 2.0
    let configuration: ContactTransform.Configuration
    let initialDistance: Double
    let distance: Double
    let angle: Double
    let translation: Double
    let pinchMotion: Double
    let rotationMotion: Double
    let minimumContactTravel: Double
    let netAlignment: Double
    let features: VelocityTiltFeatures?
    let tiltPrior: Double

    var logSpacing: Double { log(distance / initialDistance) }
    var rotationStrength: Double { abs(angle) / (Self.geometryTiltDegrees * .pi / 180) * tiltPrior }
    var pinchStrength: Double { abs(logSpacing) / Self.geometryPinchLogSpacing }
    var radialDirection: Int { logSpacing > 0 ? 1 : -1 }
    var turnDirection: Int { (features?.angularVelocity ?? 0) > 0 ? 1 : -1 }
    var usesTangentialMotion: Bool { configuration.usesRelativeMotion || configuration.tiltModel != .geometry }
    var pinchGeometryChecks: [GestureClassifierCheck] {
        [.minimum("Spacing change", abs(logSpacing), Self.geometryPinchLogSpacing),
         .minimum("Radial travel", pinchMotion, 0.5, "mm")]
    }
    var tiltGeometryChecks: [GestureClassifierCheck] {
        var checks: [GestureClassifierCheck] = [
            .minimum("Turn angle after prior", abs(angle) * 180 / .pi * tiltPrior, Self.geometryTiltDegrees, "°"),
            .minimum("Angular travel", rotationMotion, 0.5, "mm"),
            .minimum("Angular versus shared travel", rotationMotion, translation * 0.9, "mm")
        ]
        if configuration.tiltModel != .geometry && configuration.tiltModel != .paths {
            checks.append(.minimum("Tangential coordination", features?.confidence ?? 0, 0.45))
        }
        return checks
    }
    var geometryTiltPossible: Bool { tiltGeometryChecks.allSatisfy(\.passed) }
    var geometryPinchPossible: Bool { pinchGeometryChecks.allSatisfy(\.passed) }
    // Both geometry fallbacks inspect a window of meaningful physical motion.
    // Spacing can establish that observation window before a turn develops;
    // each fallback still requires its own continuous 32 ms eligibility.
    var hasGeometryEvidence: Bool { max(rotationStrength, pinchStrength) >= 1 }
}

extension GestureClassifier {
    func signal(for input: GestureMeasurements) -> GestureClassifierSignal {
        typealias Check = GestureClassifierCheck
        let config = input.configuration
        let features = input.features
        let radiansToDegrees = 180 / Double.pi
        func make(_ checks: [Check], duration: TimeInterval = 0, direction: Int = 0,
                  hasEvidence: Bool = true, window: TimeInterval = 0) -> GestureClassifierSignal {
            GestureClassifierSignal(classifier: self, confidence: checks.map(\.support).min() ?? 0,
                eligible: checks.allSatisfy(\.passed), direction: direction, persistence: duration,
                hasEvidence: hasEvidence, observationWindow: window, checks: checks,
                prior: intent == .rotation ? input.tiltPrior : 1)
        }
        switch self {
        case .radialPinch, .decisiveRadialPinch:
            let decisive = self == .decisiveRadialPinch
            return make([
                .gate("Relative-motion classifier enabled", config.usesRelativeMotion),
                .minimum("Radial coordination", features?.pinchConfidence ?? 0, decisive ? 0.97 : 0.85),
                .minimum("Radial speed", abs(features?.radialVelocity ?? 0), decisive ? 100 : 60, "mm/s"),
                .minimum("Spacing change", abs(input.logSpacing), log(decisive ? 1.08 : 1.06)),
                .minimum("Radial travel", input.pinchMotion, decisive ? 1 : 0.5, "mm"),
                .minimum("Radial versus angular travel", input.pinchMotion, input.rotationMotion * (decisive ? 4 : 2.5), "mm"),
                .minimum("Radial versus shared travel", input.pinchMotion, input.translation * (decisive ? 1.25 : 1), "mm"),
                .gate("Radial velocity agrees with spacing direction", (features?.radialVelocity ?? 0) * input.logSpacing > 0)
            ], duration: decisive ? 0.008 : 0.024, direction: input.radialDirection)

        case .spacingPinch:
            return make([
                .gate("Spacing classifier enabled", config.earlyPinchRatio != nil),
                .minimum("Spacing change", abs(input.logSpacing), log(1 + (config.earlyPinchRatio ?? 0.06))),
                .minimum("Radial travel", input.pinchMotion, 0.5, "mm"),
                .maximum("Effective turn", abs(input.angle) * radiansToDegrees * input.tiltPrior, 1, "°"),
                .minimum("Radial versus shared travel", input.pinchMotion, input.translation, "mm")
            ], duration: config.earlyPinchDuration, direction: input.radialDirection)

        case .geometryPinch:
            var checks = input.pinchGeometryChecks
            // A spacing-led start can develop into a turn. This local geometry
            // condition retains that ambiguity protection without depending on
            // the readiness or confidence of any Tilt classifier.
            if input.geometryTiltPossible {
                checks.append(Check(name: "Turn ambiguity", value: input.rotationStrength, comparison: .below,
                                    threshold: input.pinchStrength * 0.9, unit: ""))
            }
            return make(checks, duration: 0.032, direction: input.radialDirection,
                        hasEvidence: input.hasGeometryEvidence, window: config.ambiguityDuration)

        case .tangentialTilt, .decisiveTangentialTilt:
            let decisive = self == .decisiveTangentialTilt
            var checks: [Check] = [
                .gate("Tangential-motion classifier enabled", input.usesTangentialMotion),
                .minimum("Tangential coordination after prior", (features?.confidence ?? 0) * input.tiltPrior, decisive ? 0.95 : 0.7),
                .minimum("Turn angle", abs(input.angle) * radiansToDegrees, decisive ? 2 : 1, "°"),
                .minimum("Angular travel", input.rotationMotion, decisive ? 1 : 0.5, "mm")
            ]
            if decisive {
                checks += [
                    .minimum("Angular versus radial travel", input.rotationMotion, input.pinchMotion * 3, "mm"),
                    .minimum("Angular versus shared travel", input.rotationMotion, input.translation * 1.25, "mm"),
                    .gate("Angular velocity agrees with turn direction", (features?.angularVelocity ?? 0) * input.angle > 0)
                ]
            }
            if config.tiltModel == .paths {
                checks.append(.minimum("Position-path support", features?.path?.rotationSupport ?? 0, 0.5))
            }
            return make(checks, duration: decisive ? 0.008 : 0.024, direction: input.turnDirection)

        case .geometryTilt:
            var checks = input.tiltGeometryChecks
            if input.geometryPinchPossible {
                checks.append(.minimum("Turn versus spacing strength", input.rotationStrength, input.pinchStrength * 0.9))
            }
            return make(checks, duration: 0.032, direction: input.angle > 0 ? 1 : -1,
                        hasEvidence: input.hasGeometryEvidence, window: config.ambiguityDuration)

        case .coordinatedSwipe:
            return make([
                .gate("Early Swipe classifier enabled", config.usesEarlyIntent),
                .minimum("Shared travel", input.translation, 0.75, "mm"),
                .minimum("Each contact's travel", input.minimumContactTravel, 0.5, "mm"),
                .minimum("Displacement alignment", input.netAlignment, 0.95),
                .minimum("Velocity alignment", features?.velocityAlignment ?? 0, 0.95),
                .minimum("Contact speed balance", features?.speedBalance ?? 0, 0.5),
                .minimum("Shared speed", features?.commonSpeed ?? 0, 25, "mm/s"),
                .minimum("Shared versus relative travel", input.translation, max(input.pinchMotion, input.rotationMotion) * 3, "mm")
            ])

        case .translationSwipe:
            return make([
                .minimum("Shared travel", input.translation, 3, "mm"),
                Check(name: "Relative versus shared travel", value: max(input.pinchMotion, input.rotationMotion) * 1.5,
                      comparison: .below, threshold: input.translation, unit: "mm")
            ])
        }
    }
}
