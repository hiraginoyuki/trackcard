import Foundation
import TrackpadCore

/// Optional local instrumentation. Times use host uptime except sourceTimestamp;
/// visual-submission marks a compositor flush, not observed display presentation.
@MainActor
final class RecognitionTrace {
    private let file: FileHandle

    static func fromEnvironment() -> RecognitionTrace? {
        guard let path = ProcessInfo.processInfo.environment["TRACKCARD_DELIVERY_TRACE"], !path.isEmpty else { return nil }
        do { return try RecognitionTrace(path: path) }
        catch { NSLog("Cannot open delivery trace: %@", error.localizedDescription); return nil }
    }

    private init(path: String) throws {
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        file = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try file.seekToEnd()
        write(["event": "start", "deliveryVersion": RecognitionDelivery.version,
               "recognizerVersion": ContactTransform.version, "time": ProcessInfo.processInfo.systemUptime])
    }

    private func write(_ event: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) else { return }
        data.append(0x0a)
        try? file.write(contentsOf: data)
    }

    func frame(deviceID: UInt64, frame: ContactFrame, receipt: RecognitionDelivery.Receipt,
               drainedAt: TimeInterval, dropped: UInt64) {
        write(["event": "frame", "deviceID": deviceID, "streamID": frame.streamID, "sequence": frame.sequence,
               "sourceTimestamp": frame.sourceTimestamp, "callbackAt": frame.callbackAt, "receivedAt": frame.receivedAt,
               "drainedAt": drainedAt, "recognitionTime": receipt.recognitionTime,
               "accepted": receipt.accepted, "canRecognize": receipt.canRecognize,
               "interrupted": receipt.interrupted, "dropped": dropped])
    }

    func decision(deviceID: UInt64, frame: ContactFrame, intent: ContactTransform.Intent, elapsed: TimeInterval) {
        write(["event": "decision", "deviceID": deviceID, "streamID": frame.streamID, "sequence": frame.sequence,
               "sourceTimestamp": frame.sourceTimestamp, "receivedAt": frame.receivedAt,
               "decidedAt": ProcessInfo.processInfo.systemUptime, "intent": intent.title, "physicalElapsed": elapsed])
    }

    func rightClick(deviceID: UInt64?, at time: TimeInterval) {
        write(["event": "right-click", "deviceID": deviceID.map { $0 as Any } ?? NSNull(),
               "eventAt": time, "handledAt": ProcessInfo.processInfo.systemUptime])
    }

    func visualSubmission(at time: TimeInterval, scale: Double, displayedScale: Double, opacity: Double, displayedOpacity: Double) {
        write(["event": "visual-submission", "tickAt": time, "submittedAt": ProcessInfo.processInfo.systemUptime,
               "targetScale": scale, "displayedScale": displayedScale,
               "targetOpacity": opacity, "displayedOpacity": displayedOpacity])
    }

    deinit { try? file.close() }
}
