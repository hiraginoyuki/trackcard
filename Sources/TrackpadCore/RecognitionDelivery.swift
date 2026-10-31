import Foundation

/// Delivery policy only; physical recognition rules and source timestamps stay
/// unchanged. Each device keeps its own continuity and native-click barrier.
public struct RecognitionDelivery: Sendable {
    public static let version = "ordered-frames-v1"
    public struct Receipt: Sendable {
        public let accepted: Bool
        public let canRecognize: Bool
        public let interrupted: Bool
        /// Strictly increasing host time for consumers that deduplicate arrival
        /// stamps. Equal host stamps are accepted only with advancing source time.
        public let recognitionTime: TimeInterval
    }
    private struct DeviceState: Sendable {
        var streamID: UInt64?
        var sequence: UInt64?
        var arrival: TimeInterval?
        var source: TimeInterval?
        var recognitionTime: TimeInterval?
        var touchingCount = 0
        var barrier: TimeInterval = -.infinity
        var awaitingRelease = false
        var needsReset = false
    }
    private var devices: [UInt64: DeviceState] = [:]
    private var globalBarrier: TimeInterval = -.infinity

    public init() {}

    public mutating func setDevices(_ ids: [UInt64]) {
        let active = Set(ids)
        devices = devices.filter { active.contains($0.key) }
        for id in ids where devices[id] == nil { devices[id] = DeviceState() }
    }

    public mutating func interrupt(deviceID: UInt64? = nil, at time: TimeInterval) {
        guard time.isFinite else { return }
        if deviceID == nil { globalBarrier = max(globalBarrier, time) }
        for id in deviceID.map({ [$0] }) ?? Array(devices.keys) {
            var state = devices[id] ?? DeviceState()
            state.barrier = max(state.barrier, time)
            state.awaitingRelease = true
            state.needsReset = true
            devices[id] = state
        }
    }

    public mutating func receive(deviceID: UInt64, streamID: UInt64, sequence: UInt64,
                                 receivedAt: TimeInterval, sourceTimestamp: TimeInterval,
                                 touchingCount: Int, drainedAt: TimeInterval,
                                 callbackAt: TimeInterval? = nil) -> Receipt {
        var state = devices[deviceID] ?? DeviceState()
        func ignored() -> Receipt {
            Receipt(accepted: false, canRecognize: false, interrupted: false, recognitionTime: receivedAt)
        }
        guard sequence > 0, receivedAt.isFinite, receivedAt >= 0, drainedAt.isFinite else { return ignored() }
        if state.streamID == streamID, let previous = state.sequence, sequence <= previous { return ignored() }
        let changedStream = state.streamID != nil && state.streamID != streamID
        let missing = !changedStream && sequence != (state.sequence.map { $0 &+ 1 } ?? 1)
        let previousArrival = changedStream ? nil : state.arrival
        let previousSource = changedStream ? nil : state.source
        let source = sourceTimestamp.isFinite && sourceTimestamp > 0 ? sourceTimestamp : nil
        let sourceAdvanced = source.flatMap { value in previousSource.map { value > $0 } } ?? false
        let invalidOrder = previousArrival.map { receivedAt < $0 || (receivedAt == $0 && !sourceAdvanced) } ?? false
        // An idle device may not publish frames. Only an existing two-contact
        // pair can lose recognition continuity across a long interval.
        let hadPair = !changedStream && state.touchingCount == 2
        let gap = hadPair && (previousArrival.map { receivedAt - $0 > 0.25 } ?? false)
        let sourceGap = hadPair && (source.flatMap { value in previousSource.map { value - $0 > 0.25 || value < $0 } } ?? false)
        let capturedAt = callbackAt.flatMap { $0.isFinite && $0 >= 0 && $0 <= receivedAt ? $0 : nil } ?? receivedAt
        let stale = drainedAt - capturedAt > 0.25
        if changedStream || missing || invalidOrder || gap || sourceGap || stale {
            state.awaitingRelease = true
            state.needsReset = true
        }
        state.streamID = streamID
        state.sequence = sequence
        let barrier = max(state.barrier, globalBarrier)
        let beforeClick = capturedAt <= barrier
        if beforeClick { state.awaitingRelease = true }
        let interrupted = state.needsReset
        state.needsReset = false
        // A queued pre-click release or stale snapshot must never rearm a pair.
        if !beforeClick && !stale && !invalidOrder && touchingCount < 2 { state.awaitingRelease = false }
        let recognitionTime = max(receivedAt, state.recognitionTime?.nextUp ?? receivedAt)
        if !invalidOrder {
            state.arrival = receivedAt
            state.source = source
            state.recognitionTime = recognitionTime
            state.touchingCount = touchingCount
        }
        devices[deviceID] = state
        return Receipt(accepted: !invalidOrder, canRecognize: !state.awaitingRelease && !invalidOrder,
                       interrupted: interrupted, recognitionTime: recognitionTime)
    }
}
