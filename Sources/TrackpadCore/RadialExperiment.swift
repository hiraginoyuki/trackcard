import Foundation
import CoreGraphics

public enum RadialTask: String, Codable, Sendable { case rotation, pinch, translation, hold }
public enum RadialStart: String, Codable, Sendable { case settled, immediate }
public enum RadialPace: String, Codable, Sendable { case natural, careful, quick }
public enum RadialLandingStyle: String, Codable, CaseIterable, Sendable {
    case together, staggered
    public var title: String { self == .together ? "Land together" : "One finger, then the other" }
}
public enum RadialPreset: String, CaseIterable, Sendable {
    case balanced = "Balanced · 24 trials", precision = "Small angles · 32 trials", controls = "Controls · 8 trials"
    case landing = "V2 · Fresh landing · 32 trials"
    case landingPrecision = "V2 · Small angles · 32 trials"
    case landingControls = "V2 · Landing controls · 16 trials"
    public static var current: [Self] { [.landing, .landingPrecision, .landingControls] }
    public var isDeprecated: Bool { !Self.current.contains(self) }
}
public enum RadialOutcome: String, Codable, Sendable { case acquired, lifted, interrupted, timedOut, stopped, cancelled, incompleteLanding, invalidLanding, abruptMovement }
public enum RadialPhase: String, Sendable { case waiting, settling, awaitingLift, landing, active, finished }

public struct RadialTrialConfiguration: Codable, Sendable, Identifiable {
    public var id = UUID()
    public var blockID = UUID()
    public var seed: UInt64 = 0
    public var preset: String?
    public var caseID: String
    public var number = 1
    public var count = 1
    public var task: RadialTask
    /// Degrees CCW, spacing percent, projected millimeters, or zero for hold.
    public var target: Double
    public var direction: Double = 0
    public var tolerance: Double
    public var start: RadialStart
    public var pace: RadialPace
    public var spanMM: Double?
    public var practice = false
    public var retryOf: UUID?
    /// Absent in V1 recordings. V2 reveals the target after a full lift and
    /// measures from the first newly landed pair, without another settling hold.
    public var landingStyle: RadialLandingStyle?
    public var protocolVersion: Int { landingStyle == nil ? 1 : 2 }
    public var protocolTitle: String { landingStyle == nil ? "V1 · Deprecated" : "V2 · Lift & land" }
    public static let secondContactWindow: TimeInterval = 0.1
    public var spanToleranceMM: Double { 8 }
    public var dwell: TimeInterval { task == .hold ? 0.75 : 0.35 }
    public var label: GestureLabel {
        switch task { case .rotation: .tilt; case .pinch: .pinch; case .translation: .swipe; case .hold: .none }
    }
    public var unit: String { task == .rotation ? "°" : task == .pinch ? "%" : " mm" }
    public var title: String {
        switch task {
        case .rotation: "Turn \(target > 0 ? "↺" : "↻") \(String(format: "%g", abs(target)))°"
        case .pinch: "\(target > 0 ? "Spread" : "Pinch") \(String(format: "%g", abs(target)))%"
        case .translation:
            "Move \(abs(cos(direction)) > 0.5 ? (cos(direction) > 0 ? "right" : "left") : (sin(direction) > 0 ? "up" : "down")) \(String(format: "%g", target)) mm"
        case .hold: "Hold still"
        }
    }

    public init(caseID: String, task: RadialTask, target: Double, tolerance: Double,
                start: RadialStart = .settled, pace: RadialPace = .natural, spanMM: Double? = nil) {
        self.caseID = caseID; self.task = task; self.target = target; self.tolerance = tolerance
        self.start = start; self.pace = pace; self.spanMM = spanMM
    }
}

public enum RadialTrialPlan {
    /// Counterbalanced coverage rather than a full factorial. Seeded order and
    /// every instructed condition are stored with each trial for later analysis.
    public static func make(_ preset: RadialPreset, practice: Bool, seed: UInt64) -> [RadialTrialConfiguration] {
        if !preset.isDeprecated { return makeLanding(preset, practice: practice, seed: seed) }
        var cases: [RadialTrialConfiguration] = []
        let magnitudes: [Double] = preset == .precision ? [2, 4, 8, 15] : [3, 8, 20, 45]
        if preset != .controls {
            for (a, angle) in magnitudes.enumerated() {
                for (b, sign) in [-1.0, 1.0].enumerated() {
                    for (c, start) in [RadialStart.settled, .immediate].enumerated() {
                        for span in (preset == .precision ? [25.0, 55.0] : [(a + b + c).isMultiple(of: 2) ? 25.0 : 55.0]) {
                            let pace = preset == .precision ? RadialPace.careful : [.natural, .careful, .quick][(a + 2 * b + c) % 3]
                            cases.append(RadialTrialConfiguration(caseID: "turn-\(angle * sign)-\(start.rawValue)-\(span)",
                                task: .rotation, target: angle * sign, tolerance: angle <= 4 ? 0.8 : angle <= 8 ? 1.5 : angle <= 20 ? 2.5 : 4,
                                start: start, pace: pace, spanMM: span))
                        }
                    }
                }
            }
        }
        if preset != .precision {
            for span in [25.0, 55.0] {
                cases.append(RadialTrialConfiguration(caseID: "hold-\(span)", task: .hold, target: 0, tolerance: 1, spanMM: span))
            }
            for target in [-15.0, 15.0] {
                cases.append(RadialTrialConfiguration(caseID: "pinch-\(target)", task: .pinch, target: target, tolerance: 2))
            }
            for (i, direction) in [0.0, Double.pi / 2, .pi, -.pi / 2].enumerated() {
                var trial = RadialTrialConfiguration(caseID: "move-\(i)", task: .translation, target: 10, tolerance: 1.5)
                trial.direction = direction
                cases.append(trial)
            }
        }
        var state = seed
        for i in stride(from: cases.count - 1, through: 1, by: -1) {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            cases.swapAt(i, Int(state % UInt64(i + 1)))
        }
        if practice {
            var warmup = [RadialTrialConfiguration(caseID: "practice-ccw", task: .rotation, target: 12, tolerance: 3),
                          RadialTrialConfiguration(caseID: "practice-cw", task: .rotation, target: -12, tolerance: 3),
                          RadialTrialConfiguration(caseID: "practice-hold", task: .hold, target: 0, tolerance: 1)]
            for i in warmup.indices { warmup[i].practice = true }
            cases = warmup + cases
        }
        let blockID = UUID()
        for i in cases.indices {
            cases[i].blockID = blockID; cases[i].seed = seed; cases[i].number = i + 1; cases[i].count = cases.count
            cases[i].preset = preset.rawValue
        }
        return cases
    }

    private static func makeLanding(_ preset: RadialPreset, practice: Bool, seed: UInt64) -> [RadialTrialConfiguration] {
        var cases: [RadialTrialConfiguration] = []
        let small = preset == .landingPrecision
        for landing in RadialLandingStyle.allCases {
            if preset != .landingControls {
                for magnitude in small ? [2.0, 4, 8, 15] : [3.0, 8, 20, 45] {
                    for sign in [-1.0, 1.0] {
                        for span in [25.0, 55.0] {
                            let target = magnitude * sign
                            var trial = RadialTrialConfiguration(caseID: "v2/turn/\(target)/\(span)/\(landing.rawValue)",
                                task: .rotation, target: target, tolerance: magnitude <= 4 ? 0.8 : magnitude <= 8 ? 1.5 : magnitude <= 20 ? 2.5 : 4,
                                start: .immediate, pace: small ? .careful : .natural, spanMM: span)
                            trial.landingStyle = landing
                            cases.append(trial)
                        }
                    }
                }
            } else {
                // The same eight physical controls cross both landing prompts.
                var controls = make(.controls, practice: false, seed: 0)
                for index in controls.indices {
                    controls[index].id = UUID()
                    controls[index].caseID = "v2/\(controls[index].caseID)/\(landing.rawValue)"
                    controls[index].start = .immediate
                    controls[index].landingStyle = landing
                }
                cases += controls
            }
        }
        var state = seed
        for index in stride(from: cases.count - 1, through: 1, by: -1) {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            cases.swapAt(index, Int(state % UInt64(index + 1)))
        }
        if practice {
            var warmup = [
                RadialTrialConfiguration(caseID: "v2/practice-ccw", task: .rotation, target: 12, tolerance: 3, start: .immediate, spanMM: 40),
                RadialTrialConfiguration(caseID: "v2/practice-cw", task: .rotation, target: -12, tolerance: 3, start: .immediate, spanMM: 40),
                RadialTrialConfiguration(caseID: "v2/practice-hold", task: .hold, target: 0, tolerance: 1, start: .immediate, spanMM: 40)
            ]
            for index in warmup.indices {
                warmup[index].practice = true
                warmup[index].landingStyle = index == 1 ? .staggered : .together
            }
            cases = warmup + cases
        }
        let blockID = UUID()
        for index in cases.indices {
            cases[index].blockID = blockID; cases[index].seed = seed
            cases[index].number = index + 1; cases[index].count = cases.count; cases[index].preset = preset.rawValue
        }
        return cases
    }
}

public struct RadialLandingPreparation: Codable, Sendable {
    public var deviceID: UInt64
    public var adjustedAt: TimeInterval
    public var spanMM: Double
    public var releasedAt: TimeInterval?
    public var targetTime: TimeInterval?
    public var firstContactTime: TimeInterval?
    public var pairTime: TimeInterval?
}

public struct RadialCue: Codable, Sendable {
    public var time: TimeInterval
    public var sampleTime: TimeInterval
    public var deviceID: UInt64
    public var paths: [Int32]
    public var pointsMM: [CGPoint]
    public var initialSpeedMMPerSecond: Double?
    public var baselineDuration: TimeInterval
}

public struct RadialMeasurement: Codable, Sendable {
    public var time: TimeInterval
    public var rotation: Double
    public var spacingPercent: Double
    public var translation: CGPoint
    public var value: Double
    public var error: Double
    public var absoluteError: Double
}

public struct RadialResult: Codable, Sendable {
    public var outcome: RadialOutcome
    public var endedAt: TimeInterval
    public var final: RadialMeasurement?
    public var reactionTime: TimeInterval?
    public var firstTargetTime: TimeInterval?
    public var settlingTime: TimeInterval?
    public var peakOvershoot: Double
}

public struct RadialTrialRecord: Codable, Sendable {
    public var schemaVersion = 1
    public var configuration: RadialTrialConfiguration
    public var cue: RadialCue?
    public var result: RadialResult?
    public var preparation: RadialLandingPreparation?
    public init(_ configuration: RadialTrialConfiguration) {
        self.configuration = configuration; schemaVersion = configuration.protocolVersion
    }
}

public struct RadialTrialEvent: Codable, Sendable {
    public var time: TimeInterval
    public var kind: String
    public var trialID: UUID
    public var cue: RadialCue?
    public var result: RadialResult?
    public var preparation: RadialLandingPreparation? = nil
}

/// A continuation is armed by a finished trial, but starts only after a full
/// release and a fresh two-finger chord on the performing device.
public struct RadialContinuationGate: Sendable {
    public enum Action: Sendable { case advance, retry }
    public enum Decision: Sendable { case wait, start, cancel }
    public let action: Action
    public let deviceID: UInt64
    public let after: TimeInterval
    public private(set) var releasedAt: TimeInterval?
    public var awaitingRelease: Bool { releasedAt == nil || invalidChord }
    public var awaitingContact: Bool { !awaitingRelease }
    private var firstContactTime: TimeInterval?
    private var pairTime: TimeInterval?
    private var lastTime: TimeInterval = -.infinity
    private var count = 0
    private var invalidChord = false
    private var cursorMoved = false
    private var cancelled = false

    public init(action: Action, deviceID: UInt64, after: TimeInterval) {
        self.action = action; self.deviceID = deviceID; self.after = after
    }

    public mutating func receive(deviceID: UInt64, time: TimeInterval, count: Int) {
        guard deviceID == self.deviceID, time.isFinite, time >= after, time > lastTime else { return }
        lastTime = time; self.count = count
        guard let releasedAt else {
            if count == 0 { self.releasedAt = time }
            return
        }
        guard time > releasedAt else { return }
        if count == 0 {
            if cursorMoved, pairTime == nil { cancelled = true; return }
            self.releasedAt = time; firstContactTime = nil; pairTime = nil; invalidChord = false; cursorMoved = false
            return
        }
        if firstContactTime == nil { firstContactTime = time }
        if count > 2 || (count == 1 && pairTime != nil) { invalidChord = true }
        if count == 2, pairTime == nil {
            pairTime = time
            if time > firstContactTime! + RadialTrialConfiguration.secondContactWindow { invalidChord = true }
        }
    }

    /// Return true while one-finger pointer motion may still become a chord.
    /// The pending motion cancels automatically if no second contact follows.
    public mutating func deferCursorMovement(deviceID: UInt64, at time: TimeInterval) -> Bool {
        guard deviceID == self.deviceID, releasedAt != nil, count == 1, !invalidChord,
              let firstContactTime, time >= firstContactTime,
              time <= firstContactTime + RadialTrialConfiguration.secondContactWindow else { return false }
        cursorMoved = true
        return true
    }

    public func decision(at time: TimeInterval) -> Decision {
        guard time.isFinite, time >= lastTime else { return .wait }
        if cancelled { return .cancel }
        if cursorMoved, let firstContactTime, time > firstContactTime + RadialTrialConfiguration.secondContactWindow,
           count != 2 || invalidChord { return .cancel }
        guard releasedAt != nil, count == 2, !invalidChord, pairTime != nil,
              time <= lastTime + RadialTrialConfiguration.secondContactWindow else { return .wait }
        return .start
    }
}

/// A target task driven solely by physical contact geometry, independently of
/// the production recognizer. Time is relative to its normal recording session.
public struct RadialTrialEngine: Sendable {
    public private(set) var record: RadialTrialRecord
    public private(set) var phase = RadialPhase.waiting
    public private(set) var measurement: RadialMeasurement?
    public private(set) var currentSpan: Double?
    public private(set) var currentPointsMM: [CGPoint] = []
    public var deviceID: UInt64? { record.cue?.deviceID ?? record.preparation?.deviceID ?? latest?.device }
    public private(set) var holdProgress = 0.0
    private var pending: [RadialTrialEvent] = []
    private var latest: (device: UInt64, time: Double, sourceTime: Double?, paths: [Int32], points: [CGPoint])?
    private var stableSince: Double?
    private var latestSpeed: Double?
    private var holdSince: Double?
    private var reactionTime: Double?
    private var firstTargetTime: Double?
    private var overshoot = 0.0
    private var previousAngle: Double = 0
    private var angle = 0.0
    private var lastFrameTime: TimeInterval = -.infinity
    private var landingContactCount = 0

    public init(_ configuration: RadialTrialConfiguration) { record = RadialTrialRecord(configuration) }

    public mutating func takeEvents() -> [RadialTrialEvent] {
        defer { pending.removeAll(keepingCapacity: true) }
        return pending
    }

    public mutating func receive(_ frame: RecordedContactFrame, sizeMM: CGSize) {
        guard phase != .finished, frame.time.isFinite, frame.time >= 0,
              sizeMM.width.isFinite, sizeMM.height.isFinite, sizeMM.width > 0, sizeMM.height > 0 else { return }
        if let cue = record.cue, frame.deviceID != cue.deviceID { return }
        if let preparation = record.preparation, frame.deviceID != preparation.deviceID { return }
        if let latest, latest.device != frame.deviceID { return }
        guard frame.time > lastFrameTime else { return }
        lastFrameTime = frame.time
        let contacts = frame.contacts.filter { $0.stage == 3 || $0.stage == 4 }.sorted { $0.id < $1.id }
        if phase == .awaitingLift {
            if contacts.isEmpty, frame.time > record.preparation!.adjustedAt {
                record.preparation?.releasedAt = frame.time
                latest = nil; latestSpeed = nil; currentSpan = nil; currentPointsMM = []
                pending.append(RadialTrialEvent(time: frame.time, kind: "released", trialID: record.configuration.id,
                                               preparation: record.preparation))
            } else if !contacts.isEmpty { record.preparation?.releasedAt = nil }
            return
        }
        if phase == .landing {
            landingContactCount = contacts.count
            guard let targetTime = record.preparation?.targetTime, frame.time > targetTime else { return }
            if contacts.isEmpty {
                if record.preparation?.firstContactTime != nil { finish(.incompleteLanding, at: frame.time) }
                return
            }
            if record.preparation?.firstContactTime == nil { record.preparation?.firstContactTime = frame.time }
            guard frame.time <= record.preparation!.firstContactTime! + RadialTrialConfiguration.secondContactWindow else {
                finish(.incompleteLanding, at: frame.time); return
            }
            if contacts.count == 1 { return }
            if contacts.count != 2 { finish(.interrupted, at: frame.time); return }
        }
        guard contacts.count == 2, contacts[0].id != contacts[1].id else {
            if record.cue != nil || phase == .landing { finish(contacts.isEmpty ? .lifted : .interrupted, at: frame.time) }
            else { resetPreparation() }
            return
        }
        let points = contacts.map { CGPoint(x: $0.position.x * sizeMM.width, y: $0.position.y * sizeMM.height) }
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            if phase == .landing { finish(.invalidLanding, at: frame.time) }
            return
        }
        let paths = contacts.map(\.id)
        let vector = CGPoint(x: points[1].x - points[0].x, y: points[1].y - points[0].y)
        let span = hypot(vector.x, vector.y)
        currentSpan = span
        currentPointsMM = points
        guard span >= 10 else {
            if phase == .landing { finish(.invalidLanding, at: frame.time) }
            else if record.cue != nil { finish(.interrupted, at: frame.time) }
            else { resetPreparation() }
            return
        }
        if phase == .landing, let targetTime = record.preparation?.targetTime {
            let cue = RadialCue(time: targetTime, sampleTime: frame.time, deviceID: frame.deviceID, paths: paths,
                               pointsMM: points, baselineDuration: 0)
            record.preparation?.pairTime = frame.time
            record.cue = cue; phase = .active
            previousAngle = atan2(vector.y, vector.x)
            latest = (frame.deviceID, frame.time, frame.sourceTimestamp.isFinite && frame.sourceTimestamp > 0 ? frame.sourceTimestamp : nil, paths, points)
            measurement = Self.measure(points: points, cue: cue, configuration: record.configuration, angle: 0, at: frame.time)
            pending.append(RadialTrialEvent(time: frame.time, kind: "cue", trialID: record.configuration.id,
                                           cue: cue, preparation: record.preparation))
            return
        }
        let samePair = latest.map { $0.paths == paths } ?? false
        if let cue = record.cue, paths != cue.paths { finish(.interrupted, at: frame.time); return }
        let arrivalInterval = latest.map { frame.time - $0.time } ?? .infinity
        let sourceTime = frame.sourceTimestamp.isFinite && frame.sourceTimestamp > 0 ? frame.sourceTimestamp : nil
        // Bluetooth may deliver consecutive sensor frames a few microseconds
        // apart. Derivatives use the hardware clock when it advances; cue,
        // dwell and freshness timing remain on the recording/rendering clock.
        let interval: TimeInterval
        if let sourceTime, let previous = latest?.sourceTime, sourceTime > previous {
            interval = sourceTime - previous
        } else { interval = arrivalInterval }
        let previousSpeed = latestSpeed
        var speed: Double?
        if let latest, samePair, arrivalInterval <= 0.05, interval <= 0.05 {
            speed = zip(points, latest.points).map { hypot($0.x - $1.x, $0.y - $1.y) / interval }.max()
        }
        latestSpeed = speed
        if record.cue == nil {
            let spanOK = record.configuration.spanMM.map { abs(span - $0) <= record.configuration.spanToleranceMM } ?? true
            if spanOK, let speed, speed <= 8 {
                if stableSince == nil { stableSince = frame.time }
                phase = .settling
            } else { stableSince = nil; phase = .waiting }
        }
        latest = (frame.deviceID, frame.time, sourceTime, paths, points)
        guard let cue = record.cue, frame.time >= cue.time else { return }
        guard arrivalInterval <= 0.1, interval <= 0.1 else { finish(.interrupted, at: frame.time); return }
        let nextAngle = atan2(vector.y, vector.x)
        angle += atan2(sin(nextAngle - previousAngle), cos(nextAngle - previousAngle)) * 180 / .pi
        previousAngle = nextAngle
        let sample = Self.measure(points: points, cue: cue, configuration: record.configuration, angle: angle, at: frame.time)
        let old = measurement
        measurement = sample
        let c = record.configuration
        let sign = c.target < 0 ? -1.0 : 1.0
        overshoot = max(overshoot, max(0, sample.error * sign))
        let moved = abs(sample.rotation) >= 0.5 || abs(sample.spacingPercent) >= 1 || hypot(sample.translation.x, sample.translation.y) >= 0.5
        if reactionTime == nil, moved { reactionTime = max(0, frame.time - cue.time) }
        // Require a fresh, sizable jump and a sharp speed increase. Ordinary
        // fast turns, small sensor jitter, and pre-cue spacing stay valid.
        if let speed, let previousSpeed, speed >= 300, speed - previousSpeed >= 200, speed * interval >= 2 {
            finish(.abruptMovement, at: frame.time)
            return
        }
        let within = sample.absoluteError <= c.tolerance
        if within, firstTargetTime == nil { firstTargetTime = max(0, frame.time - cue.time) }
        let rate = old.map { abs(sample.value - $0.value) / max(0.001, interval) } ?? .infinity
        let speedLimit = c.task == .rotation || c.task == .pinch ? 15.0 : 8.0
        if within, rate <= speedLimit {
            if holdSince == nil { holdSince = frame.time }
            holdProgress = min(1, (frame.time - holdSince!) / c.dwell)
            if frame.time - holdSince! >= c.dwell { finish(.acquired, at: frame.time) }
        } else { holdSince = nil; holdProgress = 0 }
    }

    /// The cue is revealed on the main rendering tick, never backdated to a
    /// queued sensor sample. Its exact baseline and observed speed are saved.
    public mutating func tick(at time: TimeInterval) {
        guard phase != .finished, time.isFinite, time >= 0 else { return }
        if phase == .awaitingLift, let released = record.preparation?.releasedAt, time >= released {
            record.preparation?.targetTime = time
            phase = .landing
            pending.append(RadialTrialEvent(time: time, kind: "target", trialID: record.configuration.id,
                                           preparation: record.preparation))
            return
        }
        if phase == .awaitingLift { return }
        if phase == .landing, let target = record.preparation?.targetTime {
            if landingContactCount == 1, let first = record.preparation?.firstContactTime,
               time > first + RadialTrialConfiguration.secondContactWindow { finish(.incompleteLanding, at: time) }
            else if time - target >= 10 { finish(.timedOut, at: time) }
            return
        }
        if let cue = record.cue {
            if time - (latest?.time ?? cue.time) > 0.25 { finish(.interrupted, at: time) }
            else if time - cue.time >= 10 { finish(.timedOut, at: time) }
        } else if let latest, time >= latest.time, time - latest.time <= 0.05 {
            let c = record.configuration
            let spanOK = c.spanMM.map { abs((currentSpan ?? 0) - $0) <= c.spanToleranceMM } ?? true
            let stable = stableSince.map { time - $0 >= 0.45 } == true
            if spanOK, c.landingStyle != nil, stable {
                record.preparation = RadialLandingPreparation(deviceID: latest.device, adjustedAt: time, spanMM: currentSpan!)
                phase = .awaitingLift
                pending.append(RadialTrialEvent(time: time, kind: "prepared", trialID: c.id, preparation: record.preparation))
            } else if spanOK, c.landingStyle == nil, (c.start == .immediate || stable) {
                let cue = RadialCue(time: time, sampleTime: latest.time, deviceID: latest.device, paths: latest.paths,
                    pointsMM: latest.points, initialSpeedMMPerSecond: latestSpeed,
                    baselineDuration: stableSince.map { max(0, time - $0) } ?? 0)
                record.cue = cue
                previousAngle = atan2(latest.points[1].y - latest.points[0].y, latest.points[1].x - latest.points[0].x)
                phase = .active
                pending.append(RadialTrialEvent(time: time, kind: "cue", trialID: c.id, cue: cue))
            }
        }
    }

    public mutating func finish(_ outcome: RadialOutcome, at time: TimeInterval) {
        guard phase != .finished, time.isFinite, time >= 0 else { return }
        let result = RadialResult(outcome: outcome, endedAt: time, final: measurement, reactionTime: reactionTime,
            firstTargetTime: firstTargetTime, settlingTime: outcome == .acquired ? record.cue.flatMap { cue in holdSince.map { max(0, $0 - cue.time) } } : nil,
            peakOvershoot: overshoot)
        record.result = result; phase = .finished
        pending.append(RadialTrialEvent(time: time, kind: "result", trialID: record.configuration.id, result: result))
    }

    private mutating func resetPreparation() {
        latest = nil; stableSince = nil; latestSpeed = nil; currentSpan = nil; currentPointsMM = []; phase = .waiting
    }

    static func measure(points: [CGPoint], cue: RadialCue, configuration c: RadialTrialConfiguration,
                               angle: Double, at time: Double) -> RadialMeasurement {
        let baseline = cue.pointsMM
        let span = hypot(points[1].x - points[0].x, points[1].y - points[0].y)
        let initialSpan = hypot(baseline[1].x - baseline[0].x, baseline[1].y - baseline[0].y)
        let change = (span / max(0.001, initialSpan) - 1) * 100
        let translation = CGPoint(x: (points[0].x + points[1].x - baseline[0].x - baseline[1].x) / 2,
                                  y: (points[0].y + points[1].y - baseline[0].y - baseline[1].y) / 2)
        let value: Double
        let absoluteError: Double
        switch c.task {
        case .rotation: value = angle; absoluteError = abs(value - c.target)
        case .pinch: value = change; absoluteError = abs(value - c.target)
        case .translation:
            value = translation.x * cos(c.direction) + translation.y * sin(c.direction)
            absoluteError = hypot(translation.x - c.target * cos(c.direction), translation.y - c.target * sin(c.direction))
        case .hold:
            value = zip(points, baseline).map { hypot($0.x - $1.x, $0.y - $1.y) }.max() ?? 0
            absoluteError = value
        }
        return RadialMeasurement(time: time, rotation: angle, spacingPercent: change, translation: translation,
                                 value: value, error: value - c.target, absoluteError: absoluteError)
    }
}

/// Replay uses the saved cue and baseline, including for clipped selections.
/// It does not run acquisition logic again or alter a saved trial outcome.
public struct RadialTrialPlayback: Sendable {
    public private(set) var measurement: RadialMeasurement?
    private let record: RadialTrialRecord
    private var angle = 0.0
    private var previousAngle: Double?
    private var lastTime: TimeInterval = -.infinity
    public init(_ record: RadialTrialRecord) { self.record = record }

    public mutating func receive(_ frame: RecordedContactFrame, sizeMM: CGSize) {
        guard let cue = record.cue, cue.pointsMM.count == 2, frame.time >= max(cue.time, cue.sampleTime),
              frame.time > lastTime, frame.deviceID == cue.deviceID else { return }
        let contacts = frame.contacts.filter { $0.stage == 3 || $0.stage == 4 }.sorted { $0.id < $1.id }
        guard contacts.count == 2, contacts.map(\.id) == cue.paths else { return }
        let points = contacts.map { CGPoint(x: $0.position.x * sizeMM.width, y: $0.position.y * sizeMM.height) }
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return }
        let vector = CGPoint(x: points[1].x - points[0].x, y: points[1].y - points[0].y)
        let next = atan2(vector.y, vector.x)
        let previous = previousAngle ?? atan2(cue.pointsMM[1].y - cue.pointsMM[0].y, cue.pointsMM[1].x - cue.pointsMM[0].x)
        angle += atan2(sin(next - previous), cos(next - previous)) * 180 / .pi
        previousAngle = next; lastTime = frame.time
        measurement = RadialTrialEngine.measure(points: points, cue: cue, configuration: record.configuration, angle: angle, at: frame.time)
    }
}
