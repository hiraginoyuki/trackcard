import Foundation
import CoreGraphics
import Testing
@testable import TrackpadCore

private let balancedTilt = TiltThresholds(tangentialConfidence: 0.345, angularToRadialRatio: 0.4, persistence: 0.016)
private let minimumSize = GestureActionAvailability(canShrink: false)

private func actionPair(span: Double = 40, degrees: Double = 0, shift: Double = 0, ids: [Int32] = [1, 2]) -> [TransformContact] {
    let angle = degrees * .pi / 180
    return [TransformContact(id: ids[0], positionMM: CGPoint(x: 50 + shift - span / 2 * cos(angle), y: 50 - span / 2 * sin(angle)), force: 0),
            TransformContact(id: ids[1], positionMM: CGPoint(x: 50 + shift + span / 2 * cos(angle), y: 50 + span / 2 * sin(angle)), force: 0)]
}

enum ActionMapping: CaseIterable, Sendable {
    case identity, swapIDs, reverseArray, reflectX, reflectY, rotate90, rotate180
    var flipsTurn: Bool { self == .reflectX || self == .reflectY }
    func apply(_ contacts: [TransformContact]) -> [TransformContact] {
        let result = contacts.map { contact in
            let p = contact.positionMM
            let position: CGPoint = switch self {
            case .reflectX: CGPoint(x: 100 - p.x, y: p.y)
            case .reflectY: CGPoint(x: p.x, y: 100 - p.y)
            case .rotate90: CGPoint(x: 100 - p.y, y: p.x)
            case .rotate180: CGPoint(x: 100 - p.x, y: 100 - p.y)
            default: p
            }
            return TransformContact(id: self == .swapIDs ? 100 - contact.id : contact.id, positionMM: position, force: 0)
        }
        return self == .reverseArray ? Array(result.reversed()) : result
    }
}

private func mixedAction(_ step: Double, sign: Double = 1) -> [TransformContact] {
    actionPair(span: 40 - 0.4 * step, degrees: sign * 0.3 * step, shift: 0.2 * step)
}

private func actionDecision(context: GestureActionAvailability?, sign: Double = 1, mapping: ActionMapping = .identity,
                            subsequentContext: GestureActionAvailability? = nil, cadence: Double = 0.015,
                            bunchedArrival: Bool = false) -> (ContactTransform.Intent, Double?, GestureClassifier?) {
    var transform = ContactTransform(configuration: .init(tiltThresholds: balancedTilt))
    for index in 0...Int((0.18 / cadence).rounded()) {
        let time = Double(index) * cadence
        _ = transform.receive(mapping.apply(mixedAction(time / 0.015, sign: sign)), canBegin: true,
            at: 1 + Double(index) * (bunchedArrival ? 0.001 : cadence), sourceTimestamp: 1000 + time,
            actionAvailability: index == 0 ? context : (subsequentContext ?? context))
        if transform.intent != .undecided { return (transform.intent, transform.elapsed, transform.committedClassifier) }
    }
    return (transform.intent, nil, transform.committedClassifier)
}

@Test func actionAvailabilityMapsExactTargetsAndRejectsInvalidState() throws {
    func state(_ scale: Double, _ opacity: Double) -> GestureActionAvailability? {
        .init(scale: scale, opacity: opacity, minimumScale: 0.25, maximumScale: 1.5, minimumOpacity: 0.15)
    }
    let full = try #require(state(0.25, 1))
    #expect(!full.canShrink && full.canGrow && full.canDecreaseOpacity && !full.canIncreaseOpacity)
    let faint = try #require(state(0.25, 0.15))
    #expect(!faint.canShrink && faint.canGrow && !faint.canDecreaseOpacity && faint.canIncreaseOpacity)
    #expect(try #require(state(0.25 + 1e-6, 0.5)).canShrink)
    #expect(try #require(state(0.25 + 1e-10, 0.5)).canShrink == false)
    #expect(try #require(state(1.5, 0.5)).canGrow == false)
    for (scale, opacity) in [(Double.nan, 1), (0.25, .infinity), (0.2, 1), (2, 1), (0.25, 0.1), (0.25, 1.1)] {
        #expect(state(scale, opacity) == nil)
    }
}

@Test func minimumSizePreferenceHasAnObservableButSmallEffect() {
    let ordinary = actionDecision(context: nil)
    let preferred = actionDecision(context: minimumSize)
    #expect(ordinary.0 == .undecided && ordinary.1 == nil)
    #expect(preferred.0 == .rotation && preferred.2 == .tangentialTilt)
    #expect(abs((preferred.1 ?? 0) - 0.12) < 1e-8)
    #expect(actionDecision(context: .init()).0 == ordinary.0)
    #expect(actionDecision(context: .init(canGrow: false)).0 == ordinary.0)
}

@Test(arguments: [-1.0, 1.0]) func minimumSizeUsesTheAvailableOpacityDirection(sign: Double) {
    let atFullOpacity = GestureActionAvailability(canShrink: false, canIncreaseOpacity: false)
    let atMinimumOpacity = GestureActionAvailability(canShrink: false, canDecreaseOpacity: false)
    #expect(actionDecision(context: atFullOpacity, sign: sign).0 == (sign > 0 ? .rotation : .undecided))
    #expect(actionDecision(context: atMinimumOpacity, sign: sign).0 == (sign < 0 ? .rotation : .undecided))
    #expect(actionDecision(context: minimumSize, sign: sign).0 == .rotation)
    #expect(actionDecision(context: .init(canShrink: false, canDecreaseOpacity: false, canIncreaseOpacity: false), sign: sign).0 == .undecided)
}

@Test(arguments: ActionMapping.allCases) func actionPreferenceRespectsPathAndSpatialSymmetries(mapping: ActionMapping) {
    let result = actionDecision(context: minimumSize, mapping: mapping)
    #expect(result.0 == .rotation && result.2 == .tangentialTilt)
    #expect(abs((result.1 ?? 0) - 0.12) < 1e-8)
    let context = GestureActionAvailability(canShrink: false, canDecreaseOpacity: !mapping.flipsTurn, canIncreaseOpacity: mapping.flipsTurn)
    #expect(actionDecision(context: context, mapping: mapping).0 == .rotation)
}

@Test func actionContextLatchesOnceAndRequiresReleaseAfterPairReplacement() {
    #expect(actionDecision(context: minimumSize, subsequentContext: .init()).0 == .rotation)
    #expect(actionDecision(context: .init(), subsequentContext: minimumSize).0 == .undecided)
    // Missing context at pair start remains context-free even if it arrives later.
    #expect(actionDecision(context: nil, subsequentContext: minimumSize).0 == .undecided)
    var transform = ContactTransform(configuration: .init(tiltThresholds: balancedTilt))
    _ = transform.receive(actionPair(), canBegin: true, at: 0, actionAvailability: minimumSize)
    _ = transform.receive(actionPair(ids: [1, 3]), canBegin: true, at: 0.015, actionAvailability: .init())
    #expect(!transform.isTracking)
    _ = transform.receive([], canBegin: true, at: 0.03)
    for index in 0...12 {
        _ = transform.receive(mixedAction(Double(index)), canBegin: true, at: 0.05 + Double(index) * 0.015,
                              actionAvailability: .init())
    }
    #expect(transform.intent == .undecided)
}

@Test(arguments: [0.008, 0.015, 1.0 / 120, 0.02]) func actionPreferenceKeepsTheSensorClockUnderBunchedArrival(cadence: Double) {
    let regular = actionDecision(context: minimumSize, cadence: cadence)
    let bunched = actionDecision(context: minimumSize, cadence: cadence, bunchedArrival: true)
    #expect(regular.0 == bunched.0 && regular.2 == bunched.2)
    #expect(abs((regular.1 ?? 0) - (bunched.1 ?? 0)) < 1e-8)
    if let time = bunched.1 { #expect(time >= balancedTilt.persistence) }
}

@Test(arguments: [-1.0, 1.0]) func decisivePinchAndTiltKeepTheirOwnershipAtSizeLimits(sign: Double) {
    var pinch = ContactTransform(configuration: .init(tiltThresholds: balancedTilt))
    var tilt = pinch
    for index in 0...2 {
        _ = pinch.receive(actionPair(span: 40 + sign * 6 * Double(index)), canBegin: true, at: Double(index) * 0.008,
                          actionAvailability: minimumSize)
        _ = tilt.receive(actionPair(degrees: sign * 3 * Double(index)), canBegin: true, at: Double(index) * 0.008,
                         actionAvailability: .init(canShrink: false, canDecreaseOpacity: false, canIncreaseOpacity: false))
    }
    #expect(pinch.committedClassifier == .decisiveRadialPinch)
    #expect(tilt.committedClassifier == .decisiveTangentialTilt)
    for index in 3...12 {
        _ = pinch.receive(actionPair(span: 40 + sign * 12, degrees: Double(index) * 3), canBegin: true, at: Double(index) * 0.008,
                          actionAvailability: minimumSize)
    }
    #expect(pinch.intent == .pinch)
}

@Test func weakPinchExpansionAndTurnReversalRemoveTheExtraPreference() throws {
    for reversal in [false, true] {
        var transform = ContactTransform(configuration: .init(tiltThresholds: balancedTilt))
        for index in 0...6 {
            _ = transform.receive(mixedAction(Double(index)), canBegin: true, at: Double(index) * 0.015,
                                  actionAvailability: minimumSize)
        }
        // An outward continuation or an opposite turn occurs before Tilt commits.
        _ = transform.receive(actionPair(span: reversal ? 37.2 : 40.8, degrees: reversal ? 0.8 : 2.1, shift: 1.4),
                              canBegin: true, at: 0.105, actionAvailability: minimumSize)
        let path = try #require(transform.assessment.classifiers.first { $0.classifier == .tangentialTilt })
        let condition = try #require(path.checks.first { $0.name == "Tangential coordination after prior" })
        #expect(condition.threshold == balancedTilt.tangentialConfidence && !path.isReady)
        #expect(transform.intent != .rotation)
    }
    // Outward scaling at minimum size remains an ordinary, useful Pinch action.
    var expanding = ContactTransform(configuration: .init(tiltThresholds: balancedTilt))
    var withoutContext = expanding
    for index in 0...12 {
        let pair = actionPair(span: 40 + 0.4 * Double(index), degrees: 0.3 * Double(index), shift: 0.2 * Double(index))
        _ = expanding.receive(pair, canBegin: true, at: Double(index) * 0.015, actionAvailability: minimumSize)
        _ = withoutContext.receive(pair, canBegin: true, at: Double(index) * 0.015)
        #expect(expanding.intent == withoutContext.intent)
    }
}

@Test func minimumSizeDoesNotOverrideNativeClickOrHeldPointerProtection() throws {
    var interrupted = ContactTransform(configuration: .init(tiltThresholds: balancedTilt))
    _ = interrupted.receive(actionPair(), canBegin: true, at: 0, actionAvailability: minimumSize)
    _ = interrupted.interrupt()
    for index in 1...12 {
        #expect(interrupted.receive(mixedAction(Double(index)), canBegin: true, at: Double(index) * 0.015,
                                    actionAvailability: minimumSize) == nil)
        #expect(!interrupted.isTracking && interrupted.intent == .undecided)
    }
    _ = interrupted.receive([], canBegin: true, at: 0.20)
    _ = interrupted.receive(actionPair(), canBegin: true, at: 0.22, actionAvailability: minimumSize)
    #expect(interrupted.isTracking)
    var held = ContactTransform(configuration: .init(tiltThresholds: balancedTilt))
    for (time, x) in [(0.0, 0.0), (0.015, 2.0)] {
        _ = held.receive([TransformContact(id: 1, positionMM: CGPoint(x: x, y: 0))], canBegin: false, at: time,
                         pointerOverTarget: false, actionAvailability: minimumSize)
    }
    for index in 0...7 {
        _ = held.receive(mixedAction(Double(index)), canBegin: true, at: 0.03 + Double(index) * 0.015,
                         pointerOverTarget: true, actionAvailability: minimumSize)
        if let path = held.assessment.classifiers.first(where: { $0.classifier == .tangentialTilt }) {
            #expect(path.checks.first { $0.name == "Tangential coordination after prior" }?.threshold == balancedTilt.tangentialConfidence)
        }
    }
    #expect(held.heldPointerContactID == 1 && held.assessment.tiltPrior == 0.05)
}

@Test func recordedContextSurvivesCodableAndAllReplayPaths() throws {
    let device = RecordedDevice(id: 1, name: "Test", sizeMM: CGSize(width: 100, height: 100))
    var session = GestureRecordingSession(label: .tilt, devices: [device], at: 0, tiltThresholdsByDevice: ["1": balancedTilt])
    var frames: [[String: Any]] = []
    for index in 0...12 {
        let pair = mixedAction(Double(index))
        let contacts = pair.map { RecordedContact(id: $0.id, stage: 4,
            position: CGPoint(x: $0.positionMM.x / 100, y: $0.positionMM.y / 100), radiiMM: .zero, angle: 0) }
        let frame = RecordedContactFrame(deviceID: 1, sequence: UInt64(index + 1), time: Double(index) * 0.015,
            sourceTimestamp: 1000 + Double(index) * 0.015, contacts: contacts, actionAvailability: minimumSize)
        let roundTrip = try JSONDecoder().decode(RecordedContactFrame.self, from: JSONEncoder().encode(frame))
        #expect(roundTrip.actionAvailability == minimumSize)
        session.receive(roundTrip)
        frames.append(["arrival": frame.time, "sensor": frame.sourceTimestamp, "ids": pair.map(\.id),
            "points": pair.map { [$0.positionMM.x, $0.positionMM.y] },
            "actionAvailability": try JSONSerialization.jsonObject(with: JSONEncoder().encode(minimumSize))])
        if index == 0 {
            var oldFrame = try JSONSerialization.jsonObject(with: JSONEncoder().encode(frame)) as! [String: Any]
            oldFrame.removeValue(forKey: "actionAvailability")
            let legacy = try JSONDecoder().decode(RecordedContactFrame.self, from: JSONSerialization.data(withJSONObject: oldFrame))
            #expect(legacy.actionAvailability == nil)
        }
    }
    #expect(session.attempt.recognizerVersion == ContactTransform.version)
    #expect(session.attempt.intervals.contains { $0.kind == "Recognized Tilt" })
    let example: [String: Any] = ["ref": "test", "session": "s1", "label": "Tilt", "deviceID": "1", "builtIn": false, "frames": frames]
    let dataset = try JSONDecoder().decode(ClassifierTuningDataset.self, from: JSONSerialization.data(withJSONObject: ["session": "s1", "examples": [example]]))
    let result = try #require(dataset.evaluate(balancedTilt, deviceID: "1").first)
    let replay = TuningGestureReplay(example: dataset.examples[0], thresholds: balancedTilt, baselineThresholds: balancedTilt)
    #expect(result.decision == .rotation && replay.previewDecision?.intent == .rotation && replay.baselineDecision?.intent == .rotation)
    #expect(abs((result.time ?? 0) - (replay.previewDecision?.elapsed ?? 1)) < 1e-8)
    var comparison = ClassifierComparison(variants: ClassifierVariant.withTuning(balancedTilt))
    for frame in dataset.examples[0].frames {
        comparison.receive(frame.contacts, at: frame.arrival, sourceTimestamp: frame.sensor, actionAvailability: frame.actionAvailability)
    }
    #expect(comparison.traces.last?.decision == .rotation)
    #expect(comparison.traces.dropLast().allSatisfy { $0.variant.isCurrent == false })
}

@Test(arguments: [false, true]) func recordingExporterPreservesContextAndRecognition(hasContext: Bool) throws {
    let files = FileManager.default
    let temporary = files.temporaryDirectory.appendingPathComponent("trackcard-export-\(UUID())", isDirectory: true)
    let recordings = temporary.appendingPathComponent("recordings", isDirectory: true)
    try files.createDirectory(at: recordings, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: temporary) }

    let encoder = JSONEncoder()
    let device = RecordedDevice(id: 1, name: "Export fixture", sizeMM: CGSize(width: 100, height: 100))
    var session = GestureRecordingSession(label: .tilt, devices: [device], at: 0, tiltThresholdsByDevice: ["1": balancedTilt])
    var recordedFrames: [RecordedContactFrame] = []
    for index in 0...12 {
        let contacts = mixedAction(Double(index)).map { RecordedContact(id: $0.id, stage: 4,
            position: CGPoint(x: $0.positionMM.x / 100, y: $0.positionMM.y / 100), radiiMM: .zero, angle: 0) }
        // Later availability differs so the export must preserve each frame and the initial latch.
        let context: GestureActionAvailability? = hasContext ? (index == 0 ? minimumSize : .init()) : nil
        let frame = RecordedContactFrame(deviceID: 1, sequence: UInt64(index + 1), time: Double(index) * 0.015,
            sourceTimestamp: 1000 + Double(index) * 0.015, contacts: contacts,
            pointerOverPreview: true, actionAvailability: context)
        recordedFrames.append(frame)
        session.receive(frame)
    }
    let attempt = session.finish(at: 0.18)
    var annotations = GestureAnnotations()
    annotations.initializeContactGroups(for: attempt)
    annotations.initializeReferenceIDs(for: attempt)
    let sessionRef = try #require(annotations.referenceID(for: attempt))
    try encoder.encode(annotations).write(to: recordings.appendingPathComponent("annotations.json"))
    let summary = try encoder.encode(attempt)
    let stem = recordings.appendingPathComponent(attempt.id.uuidString.lowercased())
    try summary.write(to: stem.appendingPathExtension("json"))
    var entries: [[String: Any]] = [["kind": "header", "attempt": try JSONSerialization.jsonObject(with: summary)]]
    for frame in recordedFrames {
        entries.append(["kind": "contacts", "frame": try JSONSerialization.jsonObject(with: encoder.encode(frame))])
    }
    let log = try entries.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        .joined(separator: "\n") + "\n"
    try Data(log.utf8).write(to: stem.appendingPathExtension("jsonl"))

    let exporter = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("scripts/export-classifier-inputs.py")
    let output = temporary.appendingPathComponent("exported.json")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", exporter.path, "--recordings", recordings.path,
                         "--session", sessionRef, "--output", output.path]
    let messages = Pipe()
    process.standardOutput = messages
    process.standardError = messages
    try process.run()
    let diagnostics = String(decoding: messages.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    try #require(process.terminationStatus == 0, Comment(rawValue: diagnostics))

    var examples = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [[String: Any]])
    try #require(examples.count == 1)
    let exportedFrames = try #require(examples[0]["frames"] as? [[String: Any]])
    if !hasContext { #expect(exportedFrames.allSatisfy { $0["actionAvailability"] == nil }) }
    // Dataset preparation adds device metadata; frame payloads come directly from the exporter.
    examples[0]["deviceID"] = "1"
    examples[0]["builtIn"] = false
    let dataset = try JSONDecoder().decode(ClassifierTuningDataset.self,
        from: JSONSerialization.data(withJSONObject: ["session": sessionRef, "examples": examples]))
    let example = try #require(dataset.examples.first)
    #expect(example.frames.count == recordedFrames.count)
    #expect(example.frames.map(\.actionAvailability) == recordedFrames.map(\.actionAvailability))
    let result = try #require(dataset.evaluate(balancedTilt, deviceID: "1").first)
    let replay = TuningGestureReplay(example: example, thresholds: balancedTilt, baselineThresholds: balancedTilt)
    let recordedTilt = attempt.intervals.first { $0.kind == "Recognized Tilt" }
    if hasContext {
        let time = try #require(recordedTilt?.start)
        #expect(abs(time - 0.12) < 1e-8)
        #expect(result.decision == .rotation && result.classifier == .tangentialTilt)
        #expect(abs(try #require(result.time) - time) < 1e-8)
        for decision in [replay.previewDecision, replay.baselineDecision] {
            let decision = try #require(decision)
            #expect(decision.intent == .rotation && decision.classifier == .tangentialTilt)
            #expect(abs(decision.elapsed - time) < 1e-8)
        }
    } else {
        #expect(recordedTilt == nil && result.decision == .undecided && result.time == nil)
        #expect(replay.previewDecision == nil && replay.baselineDecision == nil)
    }
}
