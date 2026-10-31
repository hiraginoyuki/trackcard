import Foundation
import CoreGraphics

/// Prepared once from a local tuning export; slider changes reuse contacts in
/// physical millimeters and run the same recognizer as live input.
public struct ClassifierTuningDataset: Decodable, Sendable {
    public let session: String
    public let suggestedThresholds: TiltThresholds?
    public let examples: [Example]

    public struct Example: Decodable, Sendable {
        public let ref: String
        public let session: String
        public let label: String
        public let deviceID: String
        public let builtIn: Bool
        public let frames: [Frame]
    }

    public struct Frame: Decodable, Sendable {
        public let arrival: TimeInterval
        public let sensor: TimeInterval
        public let contacts: [TransformContact]
        public let pointerOverPreview: Bool?
        public let actionAvailability: GestureActionAvailability?

        private enum CodingKeys: String, CodingKey {
            case arrival, sensor, points, ids, orientations, radii, forces, pointerOverPreview, actionAvailability
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            arrival = try values.decode(Double.self, forKey: .arrival)
            sensor = try values.decode(Double.self, forKey: .sensor)
            pointerOverPreview = try values.decodeIfPresent(Bool.self, forKey: .pointerOverPreview)
            actionAvailability = try values.decodeIfPresent(GestureActionAvailability.self, forKey: .actionAvailability)
            let points = try values.decode([[Double]].self, forKey: .points)
            let ids = try values.decodeIfPresent([Int32].self, forKey: .ids)
            let angles = try values.decodeIfPresent([Double].self, forKey: .orientations)
            let radii = try values.decodeIfPresent([[Double]].self, forKey: .radii)
            let forces = try values.decodeIfPresent([Double].self, forKey: .forces)
            guard arrival.isFinite, arrival >= 0, sensor.isFinite, points.count <= 32,
                  points.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }),
                  ids.map({ $0.count == points.count }) ?? true,
                  angles.map({ $0.count == points.count }) ?? true,
                  forces.map({ $0.count == points.count }) ?? true,
                  radii.map({ $0.count == points.count && $0.allSatisfy { $0.count == 2 } }) ?? true else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid tuning frame"))
            }
            contacts = points.indices.map { i in
                TransformContact(id: ids?[i] ?? Int32(i), positionMM: CGPoint(x: points[i][0], y: points[i][1]),
                    orientation: angles?[i], radiiMM: radii.map { CGSize(width: $0[i][0], height: $0[i][1]) }, force: forces?[i])
            }
        }
    }

    public struct Result: Equatable, Sendable {
        public let ref: String
        public let session: String
        public let label: String
        public let deviceID: String
        public let decision: ContactTransform.Intent
        public let time: TimeInterval?
        public let classifier: GestureClassifier?
        public var isCorrect: Bool {
            decision.title == (["None", "Hold", "Right Click"].contains(label) ? "Undecided" : label)
        }
    }

    public func evaluate(_ thresholds: TiltThresholds, deviceID: String,
                         isCancelled: @Sendable () -> Bool = { false }) -> [Result] {
        var results: [Result] = []
        for example in examples {
            guard !isCancelled() else { return [] }
            var transform = ContactTransform(configuration: .init(tiltThresholds: example.deviceID == deviceID ? thresholds : .standard))
            var decision: ContactTransform.Intent = .undecided
            var time: TimeInterval?
            var classifier: GestureClassifier?
            for frame in example.frames {
                _ = transform.receive(frame.contacts, canBegin: true, at: frame.arrival,
                                      sourceTimestamp: frame.sensor, pointerOverTarget: frame.pointerOverPreview,
                                      actionAvailability: frame.actionAvailability)
                if decision == .undecided && transform.intent != .undecided {
                    decision = transform.intent; time = transform.elapsed; classifier = transform.committedClassifier
                }
            }
            results.append(Result(ref: example.ref, session: example.session, label: example.label, deviceID: example.deviceID,
                                  decision: decision, time: time, classifier: classifier))
        }
        return results
    }
}
