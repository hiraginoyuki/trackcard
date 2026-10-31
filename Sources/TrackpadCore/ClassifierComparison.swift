import Foundation

public struct ClassifierVariant: Sendable {
    public let id: String
    public let title: String
    public let configuration: ContactTransform.Configuration
    private let current: Bool?
    public var isCurrent: Bool { current ?? (configuration == ContactTransform.Configuration()) }

    public init(id: String, title: String, configuration: ContactTransform.Configuration, isCurrent: Bool? = nil) {
        self.id = id; self.title = title; self.configuration = configuration; self.current = isCurrent
    }

    public static func withTuning(_ thresholds: TiltThresholds) -> [Self] {
        guard thresholds != .standard else { return comparisons }
        return comparisons.map { Self(id: $0.id, title: $0.title, configuration: $0.configuration, isCurrent: false) }
            + [Self(id: "device-tilt-tuning", title: "Tuned Tilt", configuration: .init(tiltThresholds: thresholds), isCurrent: true)]
    }

    public static let comparisons: [ClassifierVariant] = {
        var variants = [ClassifierVariant(id: "baseline", title: "Baseline · 96 ms", configuration: .init(earlyPinchRatio: nil, usesRelativeMotion: false, usesEarlyIntent: false, usesIndependentClassifiers: false, timingPolicy: .legacyRelative))]
        for ratio in [0.04, 0.06, 0.08] {
            for duration in [0.016, 0.032] {
                variants.append(ClassifierVariant(id: "\(Int(ratio * 100))-\(Int(duration * 1000))",
                    title: "\(Int(ratio * 100))% spacing · \(Int(duration * 1000)) ms",
                    configuration: .init(earlyPinchRatio: ratio, earlyPinchDuration: duration, usesRelativeMotion: false, usesEarlyIntent: false, usesIndependentClassifiers: false, timingPolicy: .legacyRelative)))
            }
        }
        variants.append(ClassifierVariant(id: "vectors", title: "Velocity vectors · 24 ms", configuration: .init(tiltModel: .vectors, usesRelativeMotion: false, usesEarlyIntent: false, usesIndependentClassifiers: false, timingPolicy: .legacyRelative)))
        variants.append(ClassifierVariant(id: "vectors-axis", title: "Vectors + thumb axis · 24 ms", configuration: .init(tiltModel: .vectorsAndAxis, usesRelativeMotion: false, usesEarlyIntent: false, usesIndependentClassifiers: false, timingPolicy: .legacyRelative)))
        variants.append(ClassifierVariant(id: "relative-motion", title: "Relative motion · 24 ms", configuration: .init(usesEarlyIntent: false, usesIndependentClassifiers: false, timingPolicy: .legacyRelative)))
        variants.append(ClassifierVariant(id: "position-paths", title: "Position paths · 24 ms", configuration: .init(tiltModel: .paths, usesEarlyIntent: false, usesIndependentClassifiers: false, timingPolicy: .legacyRelative)))
        variants.append(ClassifierVariant(id: "early-intent", title: "Early Swipe + press cue", configuration: .init(usesIndependentClassifiers: false, timingPolicy: .legacyRelative)))
        variants.append(ClassifierVariant(id: "independent", title: "Independent classifiers", configuration: .init(usesMotionBoundary: false, timingPolicy: .legacyRelative)))
        variants.append(ClassifierVariant(id: "motion-boundary", title: "Competing radial motion", configuration: .init(usesRelativeTurn: false, timingPolicy: .legacyRelative)))
        variants.append(ClassifierVariant(id: "relative-turn", title: "Relative turn · 16 ms", configuration: .init(timingPolicy: .legacyRelative)))
        variants.append(ClassifierVariant(id: "source-clock-timers", title: "Source-clock timers", configuration: .init()))
        return variants
    }()
}

public struct ClassifierComparison: Sendable {
    public struct Sample: Sendable {
        public let time: TimeInterval
        public let scores: ContactTransform.Scores
        public let confidence: Double
        public let features: VelocityTiltFeatures?
        public let pressScore: Double
        public let tiltPrior: Double
        public let classifiers: [GestureClassifier.Assessment]
    }
    public struct Trace: Sendable {
        public let variant: ClassifierVariant
        public fileprivate(set) var samples: [Sample] = []
        public fileprivate(set) var decision: ContactTransform.Intent = .undecided
        public fileprivate(set) var decisionTime: TimeInterval?
        public fileprivate(set) var rightClickTime: TimeInterval?
        public fileprivate(set) var pressCueTime: TimeInterval?
        public fileprivate(set) var committedClassifier: GestureClassifier?

        public func inspection(at requestedTime: TimeInterval? = nil) -> Inspection {
            let latest = max(samples.last?.time ?? 0, decisionTime ?? 0, rightClickTime ?? 0)
            let time = requestedTime.flatMap { $0.isFinite ? max(0, $0) : nil } ?? latest
            let sample = samples.min { abs($0.time - time) < abs($1.time - time) }
            return Inspection(time: time, sample: sample,
                committedClassifier: decisionTime.map { time >= $0 - 1e-9 } == true ? committedClassifier : nil,
                isCommitFrame: decisionTime.map { abs(time - $0) < 1e-9 } ?? false,
                isVetoed: rightClickTime.map { time >= $0 - 1e-9 } ?? false)
        }
    }
    public struct Inspection: Sendable {
        public let time: TimeInterval
        public let sample: Sample?
        public let committedClassifier: GestureClassifier?
        public let isCommitFrame: Bool
        public let isVetoed: Bool
    }
    public private(set) var traces: [Trace]
    public private(set) var isCollecting = false
    public private(set) var revision: UInt64 = 0
    private var transforms: [ContactTransform]
    private var awaitingRelease = false
    private var lastArrival: TimeInterval?

    public init(variants: [ClassifierVariant] = ClassifierVariant.comparisons) {
        traces = variants.map { Trace(variant: $0) }
        transforms = variants.map { ContactTransform(configuration: $0.configuration) }
    }

    public mutating func reset() {
        self = ClassifierComparison(variants: traces.map(\.variant))
    }

    public mutating func reconfigure(variants: [ClassifierVariant]) {
        let waitForRelease = isCollecting || awaitingRelease
        let nextRevision = revision &+ 1
        self = ClassifierComparison(variants: variants)
        awaitingRelease = waitForRelease
        revision = nextRevision
    }

    public mutating func finish() {
        isCollecting = false; awaitingRelease = false; lastArrival = nil
        transforms = traces.map { ContactTransform(configuration: $0.variant.configuration) }
        revision &+= 1
    }

    public mutating func receiveRightClick(at time: TimeInterval? = nil) {
        guard isCollecting else { awaitingRelease = true; return }
        let offset = time.flatMap { time in lastArrival.map { max(0, time - $0) } } ?? 0
        for index in transforms.indices {
            traces[index].rightClickTime = transforms[index].elapsed + (offset.isFinite ? offset : 0)
            _ = transforms[index].interrupt()
        }
        isCollecting = false; awaitingRelease = true
        revision &+= 1
    }

    public mutating func receive(_ contacts: [TransformContact], at time: TimeInterval, sourceTimestamp: TimeInterval = 0,
                                 pointerOverTarget: Bool? = nil, actionAvailability: GestureActionAvailability? = nil) {
        guard time.isFinite, time >= 0, lastArrival.map({ time > $0 }) ?? true else { return }
        lastArrival = time
        guard contacts.count == 2, contacts[0].id != contacts[1].id,
              contacts.allSatisfy({ $0.positionMM.x.isFinite && $0.positionMM.y.isFinite }) else {
            if isCollecting { revision &+= 1 }
            isCollecting = false
            awaitingRelease = false
            for index in transforms.indices {
                _ = transforms[index].receive(contacts, canBegin: true, at: time,
                    sourceTimestamp: sourceTimestamp, pointerOverTarget: pointerOverTarget,
                    actionAvailability: traces[index].variant.isCurrent ? actionAvailability : nil)
            }
            return
        }
        guard !awaitingRelease else { return }
        if !isCollecting {
            traces = traces.map { Trace(variant: $0.variant) }
            isCollecting = true
        }
        for index in transforms.indices {
            _ = transforms[index].receive(contacts, canBegin: true, at: time, sourceTimestamp: sourceTimestamp,
                                          pointerOverTarget: pointerOverTarget,
                                          actionAvailability: traces[index].variant.isCurrent ? actionAvailability : nil)
            let transform = transforms[index]
            if traces[index].decisionTime == nil, transform.intent != .undecided {
                traces[index].decision = transform.intent
                traces[index].decisionTime = transform.elapsed
                traces[index].committedClassifier = transform.committedClassifier
            }
            if transform.isPressCandidate && traces[index].pressCueTime == nil { traces[index].pressCueTime = transform.elapsed }
            guard transform.isTracking else { continue }
            traces[index].samples.append(Sample(time: transform.elapsed, scores: transform.assessment.scores,
                                                confidence: transform.assessment.confidence, features: transform.assessment.tiltFeatures,
                                                pressScore: transform.assessment.pressScore, tiltPrior: transform.assessment.tiltPrior,
                                                classifiers: transform.assessment.classifiers))
            if traces[index].samples.count > 2400 { traces[index].samples.removeFirst(300) }
        }
        if transforms.allSatisfy({ !$0.isTracking }) { isCollecting = false; awaitingRelease = true }
        revision &+= 1
    }
}

extension ContactTransform.Intent {
    public var title: String {
        switch self { case .undecided: "Undecided"; case .pinch: "Pinch"; case .rotation: "Tilt"; case .movement: "Swipe" }
    }
}
