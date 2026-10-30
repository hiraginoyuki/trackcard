import Foundation

/// Frozen behavior for the twelve historical comparison variants. Production
/// rules live in GestureClassifierRules; changes here would invalidate their
/// use as timing and decision controls.
struct LegacyGestureClassifier: Sendable {
    private var vectorSince: TimeInterval?
    private var vectorDirection = 0
    private var radialSince: TimeInterval?
    private var radialDirection = 0
    private var evidenceBegan: TimeInterval?
    private var candidate: ContactTransformUpdate.Kind?
    private var candidateSince: TimeInterval = 0
    private var clearPinchSince: TimeInterval?
    private var clearPinchDirection: Int?

    private static func coherentSwipe(_ input: GestureMeasurements) -> Bool {
        input.configuration.usesEarlyIntent && input.translation >= 0.75 &&
        input.translation >= max(input.pinchMotion, input.rotationMotion) * 3 &&
        input.minimumContactTravel >= 0.5 && input.netAlignment >= 0.95 && (input.features?.velocityAlignment ?? 0) >= 0.95 &&
        (input.features?.speedBalance ?? 0) >= 0.5 && (input.features?.commonSpeed ?? 0) >= 25
    }

    static func assessment(_ input: GestureMeasurements, pressScore: Double) -> ContactTransform.Assessment {
        let configuration = input.configuration
        let features = input.features
        let distance = input.distance, initialDistance = input.initialDistance
        let angleFromStart = input.angle, translation = input.translation
        let pinchMotion = input.pinchMotion, rotationMotion = input.rotationMotion
        let tiltPrior = input.tiltPrior
        let evidence: [(ContactTransform.Intent, Double)] = [
            (.pinch, min(abs(log(distance / initialDistance)) / log(1 + (configuration.earlyPinchRatio ?? 0.08)), pinchMotion / 0.5)),
            (.rotation, min(abs(angleFromStart) / (2 * .pi / 180), rotationMotion / 0.5) *
                (configuration.tiltModel == .geometry || configuration.tiltModel == .paths ? 1 : (features?.confidence ?? 0)) * tiltPrior),
            (.movement, coherentSwipe(input) ? max(1, translation / 3) : translation / 3)
        ].sorted { $0.1 > $1.1 }
        let leading = evidence[0]
        let separation = leading.1 > 0 ? max(0, 1 - evidence[1].1 / leading.1) : 0
        var assessment = ContactTransform.Assessment(leadingIntent: leading.1 > 0 ? leading.0 : .undecided,
            confidence: min(1, leading.1) * separation, scaleRatio: distance / initialDistance)
        let total = max(1, evidence.reduce(0) { $0 + $1.1 })
        assessment.scores = ContactTransform.Scores(pinch: evidence.first { $0.0 == .pinch }!.1 / total,
                                   rotation: evidence.first { $0.0 == .rotation }!.1 / total,
                                   movement: evidence.first { $0.0 == .movement }!.1 / total)
        assessment.tiltFeatures = features
        assessment.pressScore = pressScore
        assessment.tiltPrior = tiltPrior
        return assessment
    }

    mutating func receive(_ input: GestureMeasurements, at physicalTime: TimeInterval) -> ContactTransform.Intent? {
        let configuration = input.configuration
        let features = input.features
        let distance = input.distance, initialDistance = input.initialDistance
        let angleFromStart = input.angle, translation = input.translation
        let pinchMotion = input.pinchMotion, rotationMotion = input.rotationMotion
        let tiltPrior = input.tiltPrior
        if Self.coherentSwipe(input) || (translation >= 3 && translation > max(pinchMotion, rotationMotion) * 1.5) {
            return .movement
        }
        // Keep the ambiguity window for mixed spacing/rotation evidence:
        // turns often begin with a small spacing change. A clear pinch can
        // take a shorter path below. Source time keeps batched Bluetooth
        // callbacks from compressing either evidence window.
        let rotationStrength = abs(angleFromStart) / (2 * .pi / 180) * tiltPrior
        let logSpacing = log(distance / initialDistance)
        let pinchStrength = abs(logSpacing) / log(1.08)
        let vectorReady = (configuration.usesRelativeMotion || configuration.tiltModel != .geometry) && (features?.confidence ?? 0) * tiltPrior >= 0.7 &&
            abs(angleFromStart) >= .pi / 180 && rotationMotion >= 0.5 &&
            (configuration.tiltModel != .paths || (features?.path?.rotationSupport ?? 0) >= 0.5)
        let direction = (features?.angularVelocity ?? 0) > 0 ? 1 : -1
        if !vectorReady { vectorSince = nil }
        else if vectorSince == nil || vectorDirection != direction { vectorSince = physicalTime; vectorDirection = direction }
        // Compare radial and tangential travel in the same physical units.
        // Brief real pinches can contain several degrees of incidental
        // rotation and finish before the mixed-evidence fallback window.
        let radialReady = configuration.usesRelativeMotion && (features?.pinchConfidence ?? 0) >= 0.85 &&
            abs(features?.radialVelocity ?? 0) >= 60 &&
            abs(logSpacing) >= log(1.06) && pinchMotion >= 0.5 &&
            pinchMotion >= rotationMotion * 2.5 && pinchMotion >= translation &&
            (features?.radialVelocity ?? 0) * logSpacing > 0
        let radialDirection = logSpacing > 0 ? 1 : -1
        if !radialReady { radialSince = nil }
        else if radialSince == nil || self.radialDirection != radialDirection {
            radialSince = physicalTime; self.radialDirection = radialDirection
        }
        let rotationReady = rotationStrength >= 1 && rotationMotion >= 0.5 && rotationMotion >= translation * 0.9 &&
            !radialReady && (configuration.tiltModel == .geometry || configuration.tiltModel == .paths ||
                            (features?.confidence ?? 0) >= 0.45)
        let pinchReady = pinchStrength >= 1 && pinchMotion >= 0.5
        let next: ContactTransformUpdate.Kind?
        if rotationReady && (!pinchReady || rotationStrength >= pinchStrength * 0.9) { next = .rotate }
        else if pinchReady && (!rotationReady || pinchStrength >= rotationStrength * 0.9) { next = .magnify }
        else { next = nil }
        if max(rotationStrength, pinchStrength) >= 1, evidenceBegan == nil { evidenceBegan = physicalTime }
        if next != candidate { candidate = next; candidateSince = physicalTime }
        // Require 6% spacing change, <=1 degree of rotation and radial
        // travel at least as large as shared movement for 32 ms. Reset on
        // ambiguity or direction reversal rather than accumulating bursts.
        let clearPinch = configuration.earlyPinchRatio.map { abs(logSpacing) >= log(1 + $0) } == true && pinchMotion >= 0.5 &&
            rotationStrength <= 0.5 && pinchMotion >= translation
        let pinchDirection = logSpacing > 0 ? 1 : -1
        if !clearPinch {
            clearPinchSince = nil
            clearPinchDirection = nil
        } else if clearPinchDirection != pinchDirection {
            clearPinchSince = physicalTime
            clearPinchDirection = pinchDirection
        }
        if let radialSince, physicalTime - radialSince >= 0.024 {
            return .pinch
        } else if let vectorSince, physicalTime - vectorSince >= 0.024 {
            return .rotation
        } else if !vectorReady, let clearPinchSince, physicalTime - clearPinchSince >= configuration.earlyPinchDuration {
            return .pinch
        } else {
            guard let next, let evidenceBegan, physicalTime - evidenceBegan >= configuration.ambiguityDuration,
                  physicalTime - candidateSince >= 0.032 else { return nil }
            return next == .magnify ? .pinch : .rotation
        }
    }
}
