import Foundation
import CoreGraphics

/// A causal replay of one recording. Readiness continues to be observed after
/// commitment; it never replaces the decision made by the live recognizer.
public struct TuningGestureReplay: Sendable {
    public struct State: Sendable {
        public let intent: ContactTransform.Intent
        public let classifier: GestureClassifier?
        public let checks: [GestureClassifier.Assessment]
        public let isTracking: Bool
    }

    public struct Sample: Sendable {
        public let time: TimeInterval
        public let contacts: [TransformContact]
        public let spacingChange: Double?
        public let turnDegrees: Double?
        public let baseline: State
        public let preview: State
        /// Changes on a release or a change of pair, so drawings cannot connect
        /// unrelated contacts across a gap.
        public let segment: Int
    }

    public struct Event: Sendable {
        /// Position on the recording timeline, including earlier released pairs.
        public let time: TimeInterval
        /// The recognizer's clock for the pair that produced this event.
        public let elapsed: TimeInterval
        public let sampleIndex: Int
        public let segment: Int
        public let intent: ContactTransform.Intent
        public let classifier: GestureClassifier?
    }

    public let samples: [Sample]
    public let baselineDecision: Event?
    public let previewDecision: Event?
    public let firstTiltReady: Event?
    public var startTime: TimeInterval { samples.first?.time ?? 0 }
    public var endTime: TimeInterval { samples.last?.time ?? 0 }

    public init(example: ClassifierTuningDataset.Example, thresholds: TiltThresholds,
                baselineThresholds: TiltThresholds = .standard) {
        var baseline = ContactTransform(configuration: .init(tiltThresholds: baselineThresholds))
        var preview = ContactTransform(configuration: .init(tiltThresholds: thresholds))
        var output: [Sample] = []
        var baselineEvent: Event?
        var previewEvent: Event?
        var tiltEvents: [Event] = []
        var clock: TimeInterval = 0
        var origin: TimeInterval?
        var previousFrame: ClassifierTuningDataset.Frame?
        var pair: [Int32] = []
        var initialSpacing: Double = 0
        var previousAngle: Double = 0
        var accumulatedAngle: Double = 0
        var segment = 0

        func state(_ transform: ContactTransform) -> State {
            State(intent: transform.intent, classifier: transform.committedClassifier,
                  checks: transform.isTracking ? transform.assessment.classifiers : [], isTracking: transform.isTracking)
        }

        for (index, frame) in example.frames.enumerated() {
            if let previousFrame {
                let delta = frame.sensor > 0 && previousFrame.sensor > 0 && frame.sensor > previousFrame.sensor
                    ? frame.sensor - previousFrame.sensor : frame.arrival - previousFrame.arrival
                clock += max(0, delta)
            }
            previousFrame = frame
            _ = baseline.receive(frame.contacts, canBegin: true, at: frame.arrival,
                                 sourceTimestamp: frame.sensor, pointerOverTarget: frame.pointerOverPreview,
                                 actionAvailability: frame.actionAvailability)
            _ = preview.receive(frame.contacts, canBegin: true, at: frame.arrival,
                                sourceTimestamp: frame.sensor, pointerOverTarget: frame.pointerOverPreview,
                                actionAvailability: frame.actionAvailability)
            if origin == nil && baseline.isTracking { origin = clock }
            let contacts = frame.contacts.sorted { $0.id < $1.id }
            var spacing: Double?
            var turn: Double?
            if baseline.isTracking, contacts.count == 2 {
                let vector = CGPoint(x: contacts[1].positionMM.x - contacts[0].positionMM.x,
                                     y: contacts[1].positionMM.y - contacts[0].positionMM.y)
                let distance = hypot(vector.x, vector.y)
                let angle = atan2(vector.y, vector.x)
                if pair != contacts.map(\.id) {
                    segment += 1; pair = contacts.map(\.id)
                    initialSpacing = distance; previousAngle = angle; accumulatedAngle = 0
                } else {
                    accumulatedAngle += atan2(sin(angle - previousAngle), cos(angle - previousAngle))
                    previousAngle = angle
                }
                spacing = distance - initialSpacing; turn = accumulatedAngle * 180 / .pi
            } else if !pair.isEmpty { pair = []; segment += 1 }
            output.append(Sample(time: clock, contacts: contacts, spacingChange: spacing, turnDegrees: turn,
                                 baseline: state(baseline), preview: state(preview), segment: segment))
            func event(_ transform: ContactTransform) -> Event {
                Event(time: clock, elapsed: transform.elapsed, sampleIndex: index, segment: segment,
                      intent: transform.intent, classifier: transform.committedClassifier)
            }
            if baselineEvent == nil, baseline.intent != .undecided { baselineEvent = event(baseline) }
            if previewEvent == nil, preview.intent != .undecided { previewEvent = event(preview) }
            if preview.isTracking,
               let winner = GestureClassifierBank.winner(in: preview.assessment.classifiers.filter { $0.classifier.intent == .rotation }) {
                tiltEvents.append(Event(time: clock, elapsed: preview.elapsed, sampleIndex: index, segment: segment,
                                        intent: .rotation, classifier: winner))
            }
        }
        let zero = origin ?? output.first?.time ?? 0
        samples = output.map {
            Sample(time: $0.time - zero, contacts: $0.contacts, spacingChange: $0.spacingChange,
                   turnDegrees: $0.turnDegrees, baseline: $0.baseline, preview: $0.preview, segment: $0.segment)
        }
        func aligned(_ event: Event?) -> Event? {
            event.map { Event(time: $0.time - zero, elapsed: $0.elapsed, sampleIndex: $0.sampleIndex, segment: $0.segment,
                              intent: $0.intent, classifier: $0.classifier) }
        }
        baselineDecision = aligned(baselineEvent); previewDecision = aligned(previewEvent)
        firstTiltReady = aligned(tiltEvents.first { previewEvent == nil || $0.segment == previewEvent?.segment })
    }

    /// Select the last captured frame at or before the cursor, never a future
    /// frame. Duplicate timestamps keep their original delivery order.
    public func index(at time: TimeInterval) -> Int? {
        guard !samples.isEmpty else { return nil }
        var lower = 0, upper = samples.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if samples[middle].time <= time { lower = middle + 1 } else { upper = middle }
        }
        return max(0, lower - 1)
    }
}
