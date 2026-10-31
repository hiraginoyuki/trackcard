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

public struct ContactTransformUpdate: Sendable {
    public enum Kind: Sendable { case magnify, rotate }
    public enum Phase: Sendable { case began, changed, ended }
    public let kind: Kind
    public let phase: Phase
    public let magnification: Double
    public let rotation: Double
}

/// Uses physical contact geometry, independently of synthesized AppKit gestures.
public struct ContactTransform: Sendable {
    public static let version = "minimum-scale-tilt-v9"
    public struct Configuration: Sendable, Equatable {
        public enum TiltModel: Sendable { case geometry, vectors, vectorsAndAxis, paths }
        public enum TimingPolicy: Sendable { case legacyRelative, sourceClock }
        public let tiltModel: TiltModel
        public let usesRelativeMotion: Bool
        public let usesEarlyIntent: Bool
        public let usesIndependentClassifiers: Bool
        /// Apply the radial-travel guard and developing-turn recovery to the
        /// independent classifiers. Historical comparison rules ignore it.
        public let usesMotionBoundary: Bool
        /// Recognize relative turning during shared movement, and keep the
        /// geometry fallbacks from claiming that turn before it can persist.
        public let usesRelativeTurn: Bool
        /// Historical comparisons retain their original relative tolerance.
        /// Current timers compare seconds with an allowance for source precision.
        public let timingPolicy: TimingPolicy
        public let earlyPinchRatio: Double?
        public let earlyPinchDuration: TimeInterval
        public let ambiguityDuration: TimeInterval
        public let tiltThresholds: TiltThresholds
        public init(earlyPinchRatio: Double? = 0.06, earlyPinchDuration: TimeInterval = 0.032,
                    ambiguityDuration: TimeInterval = 0.096, tiltModel: TiltModel = .geometry,
                    usesRelativeMotion: Bool = true, usesEarlyIntent: Bool = true,
                    usesIndependentClassifiers: Bool = true, usesMotionBoundary: Bool = true,
                    usesRelativeTurn: Bool = true, timingPolicy: TimingPolicy = .sourceClock,
                    tiltThresholds: TiltThresholds = .standard) {
            self.earlyPinchRatio = earlyPinchRatio
            self.earlyPinchDuration = earlyPinchDuration
            self.ambiguityDuration = ambiguityDuration
            self.tiltModel = tiltModel
            self.usesRelativeMotion = usesRelativeMotion
            self.usesEarlyIntent = usesEarlyIntent
            self.usesIndependentClassifiers = usesIndependentClassifiers
            self.usesMotionBoundary = usesMotionBoundary
            self.usesRelativeTurn = usesRelativeTurn
            self.timingPolicy = timingPolicy
            self.tiltThresholds = tiltThresholds
        }
    }
    public let configuration: Configuration
    public enum Intent: Sendable { case undecided, movement, pinch, rotation }
    public struct Scores: Sendable {
        public let pinch: Double
        public let rotation: Double
        public let movement: Double
        public static let zero = Scores(pinch: 0, rotation: 0, movement: 0)
    }
    /// A geometric evidence score for feedback, not a calibrated probability.
    public struct Assessment: Sendable {
        public let leadingIntent: Intent
        public let confidence: Double
        public let scaleRatio: Double
        public var scores: Scores = .zero
        public var tiltFeatures: VelocityTiltFeatures?
        public var pressScore: Double = 0
        public var tiltPrior: Double = 1
        public var classifiers: [GestureClassifier.Assessment] = []
    }
    public private(set) var assessment = Assessment(leadingIntent: .undecided, confidence: 0, scaleRatio: 1)
    public var intent: Intent {
        if moving { return .movement }
        return mode.map { $0 == .magnify ? .pinch : .rotation } ?? .undecided
    }
    private var lastArrival: TimeInterval?
    private var velocityTilt = VelocityTiltEvidence()
    private var peakRadialSpeed: Double = 0
    private var lastSource: TimeInterval?
    private var physicalTime: TimeInterval = 0
    private var sourceTimeResolution: TimeInterval = 0
    private var lastSampleAngle: Double = 0
    private var accumulatedAngle: Double = 0
    private var pair: [Int32] = []
    private var pairActionAvailability: GestureActionAvailability?
    private var rejected = false
    private var initialDistance: Double = 0
    private var initialCenter = CGPoint.zero
    private var initialContacts: [TransformContact] = []
    private struct SinglePreparation: Sendable {
        let id: Int32
        let origin: CGPoint
        var excursion: Double
        var lastTime: TimeInterval
        var wasOutside: Bool
    }
    private var singlePreparation: SinglePreparation?
    public private(set) var heldPointerContactID: Int32?
    private var pressSince: TimeInterval?
    private var pressPreviewActive = false
    private var moving = false
    private var previousDistance: Double = 0
    private var previousAngle: Double = 0
    private var mode: ContactTransformUpdate.Kind?
    private var legacyClassifier = LegacyGestureClassifier()
    private var classifierBank = GestureClassifierBank()
    public private(set) var committedClassifier: GestureClassifier?

    public init(configuration: Configuration = Configuration()) { self.configuration = configuration }
    public var elapsed: TimeInterval { physicalTime }

    public var isTracking: Bool { !pair.isEmpty && !rejected }
    public var isActive: Bool { mode != nil }
    /// A reversible feedback cue, never a confirmed click or a transform veto.
    public var isPressCandidate: Bool { isTracking && intent == .undecided && assessment.pressScore >= 1 }

    /// A settings change takes effect on the next pair, after any current pair
    /// releases. Never restart a partly recognized gesture under new thresholds.
    public mutating func reconfigure(_ configuration: Configuration) -> ContactTransformUpdate? {
        guard configuration != self.configuration else { return nil }
        let waitForRelease = !pair.isEmpty || rejected
        let ended = finish()
        self = ContactTransform(configuration: configuration)
        rejected = waitForRelease
        return ended
    }

    public mutating func interrupt() -> ContactTransformUpdate? {
        let ended = finish()
        rejected = true
        moving = false
        committedClassifier = nil
        classifierBank = GestureClassifierBank()
        assessment = Assessment(leadingIntent: .undecided, confidence: 0, scaleRatio: 1)
        return ended
    }

    public mutating func receive(_ contacts: [TransformContact], canBegin: Bool,
                                 at time: TimeInterval? = nil, sourceTimestamp: TimeInterval = 0,
                                 pointerOverTarget: Bool? = nil,
                                 actionAvailability: GestureActionAvailability? = nil) -> ContactTransformUpdate? {
        guard contacts.count == 2, contacts[0].id != contacts[1].id,
              contacts.allSatisfy({ $0.positionMM.x.isFinite && $0.positionMM.y.isFinite }) else {
            let preparation = singlePreparation
            let ended = finish()
            self = ContactTransform(configuration: configuration)
            // Pointer positioning with one finger precedes many real swipes.
            // Preserve its continuity until the second finger joins, rather
            // than treating every two-contact landing as equally likely Tilt.
            if configuration.usesEarlyIntent, contacts.count == 1, let contact = contacts.first,
               contact.positionMM.x.isFinite, contact.positionMM.y.isFinite {
                let arrival = time ?? ((preparation?.lastTime ?? 0) + 1 / 120)
                if arrival.isFinite {
                    if var preparation, preparation.id == contact.id,
                       arrival >= preparation.lastTime, arrival - preparation.lastTime <= 0.25 {
                        preparation.excursion = max(preparation.excursion,
                            hypot(contact.positionMM.x - preparation.origin.x, contact.positionMM.y - preparation.origin.y))
                        preparation.lastTime = arrival
                        preparation.wasOutside = preparation.wasOutside || !(pointerOverTarget ?? canBegin)
                        singlePreparation = preparation
                    } else {
                        singlePreparation = SinglePreparation(id: contact.id, origin: contact.positionMM,
                            excursion: 0, lastTime: arrival, wasOutside: !(pointerOverTarget ?? canBegin))
                    }
                }
            }
            return ended
        }
        let arrival = time ?? (lastArrival.map { $0 + 1.0 / 120 } ??
                              singlePreparation.map { $0.lastTime + 1.0 / 120 } ?? 0)
        guard arrival.isFinite, arrival >= 0, lastArrival.map({ arrival > $0 }) ?? true else { return nil }
        let source = sourceTimestamp.isFinite && sourceTimestamp > 0 ? sourceTimestamp : nil
        if let lastArrival {
            let interval = source.flatMap { current in lastSource.flatMap { current > $0 ? current - $0 : nil } } ?? (arrival - lastArrival)
            guard arrival - lastArrival <= 0.25, interval <= 0.25 else {
                let ended = finish(); rejected = true; moving = false
                return ended
            }
            physicalTime += interval
        }
        lastArrival = arrival; lastSource = source
        if let source { sourceTimeResolution = max(sourceTimeResolution, source.ulp) }
        let ordered = contacts.sorted { $0.id < $1.id }
        let ids = ordered.map(\.id)
        let vector = CGPoint(x: ordered[1].positionMM.x - ordered[0].positionMM.x,
                             y: ordered[1].positionMM.y - ordered[0].positionMM.y)
        let distance = hypot(vector.x, vector.y)
        let angle = atan2(vector.y, vector.x)
        let center = CGPoint(x: (ordered[0].positionMM.x + ordered[1].positionMM.x) / 2,
                             y: (ordered[0].positionMM.y + ordered[1].positionMM.y) / 2)
        guard !rejected else { return nil }
        if pair.isEmpty {
            pair = ids
            pairActionAvailability = actionAvailability
            rejected = !canBegin || distance < 6
            initialDistance = distance
            previousDistance = distance
            lastSampleAngle = angle
            initialCenter = center
            initialContacts = ordered
            if configuration.usesEarlyIntent, let preparation = singlePreparation,
               ids.contains(preparation.id), arrival >= preparation.lastTime, arrival - preparation.lastTime <= 0.25,
               preparation.wasOutside, pointerOverTarget ?? canBegin, preparation.excursion >= 0.5 {
                heldPointerContactID = preparation.id
                assessment.tiltPrior = 0.05
            }
            singlePreparation = nil
            previousAngle = angle
            _ = velocityTilt.receive(ordered, at: physicalTime, useAxis: configuration.tiltModel == .vectorsAndAxis,
                                     usePaths: configuration.tiltModel == .paths)
            return nil
        }
        guard pair == ids, distance >= 2 else {
            let ended = finish()
            rejected = true
            return ended
        }
        accumulatedAngle += wrapped(angle - lastSampleAngle)
        lastSampleAngle = angle
        let angleFromStart = accumulatedAngle
        let features = velocityTilt.receive(ordered, at: physicalTime, useAxis: configuration.tiltModel == .vectorsAndAxis,
                                            usePaths: configuration.tiltModel == .paths)
        var phase = ContactTransformUpdate.Phase.changed
        let translation = hypot(center.x - initialCenter.x, center.y - initialCenter.y)
        let pinchMotion = abs(distance - initialDistance) / 2
        let rotationMotion = min(distance, initialDistance) * abs(angleFromStart) / 2
        let tiltPrior = heldPointerContactID == nil ? 1.0 : 0.05
        let displacements = zip(ordered, initialContacts).map {
            CGPoint(x: $0.0.positionMM.x - $0.1.positionMM.x, y: $0.0.positionMM.y - $0.1.positionMM.y)
        }
        let travel = displacements.map { hypot($0.x, $0.y) }
        let netAlignment = (displacements[0].x * displacements[1].x + displacements[0].y * displacements[1].y) /
            max(0.000001, travel[0] * travel[1])
        peakRadialSpeed = max(peakRadialSpeed, abs(features?.radialVelocity ?? 0))
        let measurements = GestureMeasurements(configuration: configuration, initialDistance: initialDistance,
            distance: distance, angle: angleFromStart, translation: translation, pinchMotion: pinchMotion,
            rotationMotion: rotationMotion, minimumContactTravel: min(travel[0], travel[1]),
            netAlignment: netAlignment, features: features, tiltPrior: tiltPrior, peakRadialSpeed: peakRadialSpeed,
            actionAvailability: pairActionAvailability)
        var pressScore = 0.0
        if configuration.usesEarlyIntent, physicalTime >= 0.008 - 1e-9,
           let first = ordered[0].force, let second = ordered[1].force,
           let firstBaseline = initialContacts[0].force, let secondBaseline = initialContacts[1].force,
           [first, second, firstBaseline, secondBaseline].allSatisfy({ $0.isFinite && $0 >= 0 }) {
            let rise = max(first - firstBaseline, second - secondBaseline)
            let level = max(first, second)
            let quiet = max(travel[0], travel[1]) <= 1 && abs(distance - initialDistance) <= 0.8 &&
                abs(angleFromStart) <= 1.5 * .pi / 180
            if quiet && level >= 60 { pressScore = min(1, max(0, rise / 50)) }
            let sustained = level >= 120 && rise >= 60 && max(travel[0], travel[1]) <= 1.5 &&
                abs(distance - initialDistance) <= 1.5 && abs(angleFromStart) <= 3 * .pi / 180
            if !sustained { pressSince = nil }
            else if pressSince == nil { pressSince = physicalTime }
            if let pressSince, physicalTime - pressSince >= 0.016 - 1e-9 { pressScore = 1 }
            // A small pressure decrease should not flash the feedback back on.
            // Real positional evidence or a substantial release still wins.
            if pressPreviewActive && level >= 50 && rise >= 30 && max(travel[0], travel[1]) <= 1.5 &&
                abs(distance - initialDistance) <= 1.5 && abs(angleFromStart) <= 3 * .pi / 180 {
                pressScore = 1
            }
        } else { pressSince = nil }
        pressPreviewActive = pressScore >= 1
        let decision: Intent?
        if configuration.usesIndependentClassifiers {
            let classifiers = classifierBank.receive(GestureClassifier.configured(for: configuration).map { $0.signal(for: measurements) },
                at: physicalTime, timingPolicy: configuration.timingPolicy, sourceResolution: sourceTimeResolution)
            assessment = GestureClassifierBank.assessment(classifiers, measurements: measurements, pressScore: pressScore)
            let winner = GestureClassifierBank.winner(in: classifiers)
            decision = mode == nil && !moving ? winner?.intent : nil
            if decision != nil { committedClassifier = winner }
        } else {
            assessment = LegacyGestureClassifier.assessment(measurements, pressScore: pressScore)
            decision = mode == nil && !moving ? legacyClassifier.receive(measurements, at: physicalTime) : nil
        }
        if let decision {
            if decision == .movement { moving = true }
            else { mode = decision == .pinch ? .magnify : .rotate; phase = .began }
        }
        guard let mode else { return nil }
        let update = ContactTransformUpdate(kind: mode, phase: phase,
            magnification: distance / previousDistance - 1,
            rotation: wrapped(angle - previousAngle))
        previousDistance = distance
        previousAngle = angle
        return update
    }

    private mutating func finish() -> ContactTransformUpdate? {
        guard let mode else { return nil }
        self.mode = nil
        return ContactTransformUpdate(kind: mode, phase: .ended, magnification: 0, rotation: 0)
    }

    private func wrapped(_ angle: Double) -> Double { atan2(sin(angle), cos(angle)) }
}
