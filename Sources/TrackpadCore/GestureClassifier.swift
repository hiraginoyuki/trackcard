import Foundation

/// Independent recognition paths. Several paths can support the same gesture;
/// none needs another path's confidence to reach its own threshold.
public enum GestureClassifier: String, CaseIterable, Sendable {
    case decisiveRadialPinch, radialPinch, spacingPinch, geometryPinch
    case decisiveTangentialTilt, tangentialTilt, geometryTilt, developingTilt, relativeTilt
    case coordinatedSwipe, translationSwipe

    public var intent: ContactTransform.Intent {
        switch self {
        case .decisiveRadialPinch, .radialPinch, .spacingPinch, .geometryPinch: .pinch
        case .decisiveTangentialTilt, .tangentialTilt, .geometryTilt, .developingTilt, .relativeTilt: .rotation
        case .coordinatedSwipe, .translationSwipe: .movement
        }
    }

    public var title: String {
        switch self {
        case .decisiveRadialPinch: "Decisive radial motion"
        case .decisiveTangentialTilt: "Decisive tangential motion"
        case .radialPinch: "Radial motion"
        case .spacingPinch: "Sustained spacing"
        case .geometryPinch: "Pinch geometry"
        case .tangentialTilt: "Tangential motion"
        case .geometryTilt: "Tilt geometry"
        case .developingTilt: "Developing turn"
        case .relativeTilt: "Relative turn"
        case .coordinatedSwipe: "Coordinated motion"
        case .translationSwipe: "Shared travel"
        }
    }

    public var shortTitle: String {
        switch self {
        case .decisiveRadialPinch: "fast radial"
        case .decisiveTangentialTilt: "fast tangent"
        case .radialPinch: "radial"
        case .spacingPinch: "spacing"
        case .geometryPinch, .geometryTilt: "geometry"
        case .tangentialTilt: "tangent"
        case .developingTilt: "developing"
        case .relativeTilt: "relative turn"
        case .coordinatedSwipe: "coordinated"
        case .translationSwipe: "travel"
        }
    }

    // Resolve simultaneous crossings deterministically. Preserve established
    // ownership; the relative-turn path fills gaps in the existing classifiers.
    fileprivate var priority: Int {
        switch self {
        case .coordinatedSwipe: 0
        case .translationSwipe: 1
        case .decisiveRadialPinch: 2
        case .radialPinch: 3
        case .decisiveTangentialTilt: 4
        case .tangentialTilt: 5
        case .spacingPinch: 6
        case .geometryTilt: 7
        case .developingTilt: 8
        case .geometryPinch: 9
        case .relativeTilt: 10
        }
    }

    static func configured(for configuration: ContactTransform.Configuration) -> [Self] {
        allCases.filter {
            switch $0 {
            case .developingTilt: configuration.usesMotionBoundary
            case .relativeTilt: configuration.usesMotionBoundary && configuration.usesRelativeTurn
            default: true
            }
        }
    }

    public struct Assessment: Sendable {
        public let classifier: GestureClassifier
        /// Physical evidence relative to this path's threshold, bounded 0...1.
        /// These scores do not sum to one and are not probabilities.
        public let confidence: Double
        public let progress: Double
        public let isReady: Bool
        public let checks: [GestureClassifierCheck]
        public let prior: Double
        public let persistenceRemaining: TimeInterval
        public let observationRemaining: TimeInterval

        public var blockers: [String] {
            var reasons = checks.filter { !$0.passed }.map(\.explanation)
            if reasons.isEmpty {
                if persistenceRemaining > 1e-9 { reasons.append(String(format: "Persistence: %.0f ms remaining", persistenceRemaining * 1000)) }
                if observationRemaining > 1e-9 { reasons.append(String(format: "Observation window: %.0f ms remaining", observationRemaining * 1000)) }
            }
            return reasons
        }
    }
}

struct GestureClassifierSignal: Sendable {
    let classifier: GestureClassifier
    let confidence: Double
    let eligible: Bool
    var direction: Int = 0
    var persistence: TimeInterval = 0
    var hasEvidence: Bool = true
    var observationWindow: TimeInterval = 0
    var checks: [GestureClassifierCheck] = []
    var prior: Double = 1
}

/// Each path owns its timers. Persistence resets on weak evidence or a direction
/// reversal. A geometry observation window starts at its first meaningful motion
/// and lasts for the pair; it is distinct from continuous qualifying evidence.
struct GestureClassifierBank: Sendable {
    private struct History: Sendable {
        var evidenceSince: TimeInterval?
        var eligibleSince: TimeInterval?
        var direction = 0
    }
    private var histories: [GestureClassifier: History] = [:]

    mutating func receive(_ signals: [GestureClassifierSignal], at time: TimeInterval,
                          timingPolicy: ContactTransform.Configuration.TimingPolicy = .sourceClock,
                          sourceResolution: TimeInterval = 0) -> [GestureClassifier.Assessment] {
        var next: [GestureClassifier: History] = [:]
        let assessments = signals.map { signal in
            var history = histories[signal.classifier] ?? History()
            if history.direction != signal.direction {
                history.eligibleSince = nil
                history.direction = signal.direction
            }
            if signal.hasEvidence && history.evidenceSince == nil { history.evidenceSince = time }
            if !signal.eligible { history.eligibleSince = nil }
            else if history.eligibleSince == nil { history.eligibleSince = time }
            next[signal.classifier] = history
            func timer(since: TimeInterval?, duration: TimeInterval) -> (progress: Double, remaining: TimeInterval, complete: Bool) {
                let elapsed = since.map { time - $0 } ?? 0
                let remaining = max(0, duration - elapsed)
                guard let since else { return (0, remaining, false) }
                let progress = duration > 0 ? min(1, max(0, elapsed / duration)) : 1
                switch timingPolicy {
                case .legacyRelative:
                    return (progress, remaining, progress >= 1 - 1e-9)
                case .sourceClock:
                    // Source subtraction can lose more precision than the small
                    // accumulated elapsed clock suggests. Allow at least 1 ns,
                    // adapting to its ULP, while staying below a 1 µs early sample.
                    let tolerance = min(0.00000025, max(1e-9, sourceResolution + time.ulp + since.ulp))
                    let complete = remaining <= tolerance
                    return (complete ? 1 : progress, complete ? 0 : remaining, complete)
                }
            }
            let persistence = timer(since: history.eligibleSince, duration: signal.persistence)
            let observation = timer(since: history.evidenceSince, duration: signal.observationWindow)
            let progress = signal.eligible ? min(persistence.progress, observation.progress) : 0
            return GestureClassifier.Assessment(classifier: signal.classifier,
                confidence: signal.confidence.isFinite ? min(1, max(0, signal.confidence)) : 0,
                progress: progress, isReady: signal.eligible && persistence.complete && observation.complete,
                checks: signal.checks, prior: signal.prior,
                persistenceRemaining: persistence.remaining, observationRemaining: observation.remaining)
        }
        histories = next
        return assessments
    }

    static func winner(in assessments: [GestureClassifier.Assessment]) -> GestureClassifier? {
        assessments.filter(\.isReady).min { $0.classifier.priority < $1.classifier.priority }?.classifier
    }

    static func assessment(_ classifiers: [GestureClassifier.Assessment], measurements: GestureMeasurements,
                           pressScore: Double) -> ContactTransform.Assessment {
        func score(for intent: ContactTransform.Intent) -> Double {
            classifiers.filter { $0.classifier.intent == intent }.map(\.confidence).max() ?? 0
        }
        let scores = [(ContactTransform.Intent.pinch, score(for: .pinch)), (.rotation, score(for: .rotation)), (.movement, score(for: .movement))]
            .sorted { $0.1 > $1.1 }
        return ContactTransform.Assessment(leadingIntent: scores[0].1 > 0 ? scores[0].0 : .undecided,
            confidence: max(0, scores[0].1 - scores[1].1), scaleRatio: measurements.distance / measurements.initialDistance,
            scores: .init(pinch: score(for: .pinch), rotation: score(for: .rotation), movement: score(for: .movement)),
            tiltFeatures: measurements.features, pressScore: pressScore, tiltPrior: measurements.tiltPrior, classifiers: classifiers)
    }
}
