import Foundation
import TrackpadCore

struct RecordingLogEntry: Codable, Sendable {
    var kind: String
    var frame: RecordedContactFrame?
    var gesture: RecordedGestureEvent?
    var attempt: GestureAttempt?
    var preview: RecordedPreviewState?
    var radial: RadialTrialEvent?
}

struct LoadedGestureRecording: Sendable {
    var attempt: GestureAttempt
    var frames: [RecordedContactFrame]
    var previewStates: [RecordedPreviewState] = []
}

final class GestureRecordingLoader: Sendable {
    private let queue = DispatchQueue(label: "trackcard.gesture-replay", qos: .userInitiated)

    func load(_ attempt: GestureAttempt, from directory: URL, includeFrames: Bool,
              completion: @escaping @MainActor @Sendable (Result<LoadedGestureRecording, Error>) -> Void) {
        queue.async {
            let result = Result { try Self.read(attempt, from: directory, includeFrames: includeFrames) }
            let mainLoop = CFRunLoopGetMain()
            CFRunLoopPerformBlock(mainLoop, CFRunLoopMode.commonModes.rawValue) {
                MainActor.assumeIsolated { completion(result) }
            }
            CFRunLoopWakeUp(mainLoop)
        }
    }

    static func read(_ attempt: GestureAttempt, from directory: URL, includeFrames: Bool) throws -> LoadedGestureRecording {
        let url = directory.appendingPathComponent(attempt.id.uuidString.lowercased() + ".jsonl")
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var tracker = GestureContactTracker()
        var frames: [RecordedContactFrame] = []
        var previewStates: [RecordedPreviewState] = []
        var buffer = Data()
        var headerFound = false
        let decoder = JSONDecoder()
        func consume(_ line: Data.SubSequence) throws {
            guard !line.isEmpty else { return }
            let entry = try decoder.decode(RecordingLogEntry.self, from: Data(line))
            if entry.kind == "header" {
                guard entry.attempt?.id == attempt.id else { throw CocoaError(.fileReadCorruptFile) }
                headerFound = true
            }
            if let frame = entry.frame, frame.time.isFinite, frame.time >= 0 {
                tracker.receive(frame)
                if includeFrames { frames.append(frame) }
            }
            if includeFrames, let preview = entry.preview { previewStates.append(preview) }
        }
        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
            buffer.append(chunk)
            var start = buffer.startIndex
            while let newline = buffer[start...].firstIndex(of: 10) {
                try consume(buffer[start..<newline])
                start = buffer.index(after: newline)
            }
            buffer.removeSubrange(buffer.startIndex..<start)
            guard buffer.count < 2_097_152 else { throw CocoaError(.fileReadCorruptFile) }
        }
        try consume(buffer[...])
        guard headerFound else { throw CocoaError(.fileReadCorruptFile) }
        tracker.finish(at: attempt.duration)
        var indexed = attempt
        indexed.contactIndex = tracker.index
        return LoadedGestureRecording(attempt: indexed, frames: frames, previewStates: previewStates)
    }
}

/// File I/O and JSON encoding never run on the rendering thread. Each attempt
/// streams to JSONL, so raw frames don't accumulate in memory between tries.
final class GestureRecordingWriter: @unchecked Sendable {
    let dataURL: URL
    private let summaryURL: URL
    private let queue = DispatchQueue(label: "trackcard.gesture-recording", qos: .utility)
    private let handle: FileHandle
    private var failure: Error?

    init(directory: URL, attempt: GestureAttempt) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = attempt.id.uuidString.lowercased()
        dataURL = directory.appendingPathComponent(name + ".jsonl")
        summaryURL = directory.appendingPathComponent(name + ".json")
        guard FileManager.default.createFile(atPath: dataURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: dataURL)
        append(RecordingLogEntry(kind: "header", attempt: attempt))
    }

    func append(_ entry: RecordingLogEntry) {
        queue.async { [self] in
            guard failure == nil else { return }
            do {
                var line = try JSONEncoder().encode(entry)
                line.append(0x0A)
                try handle.write(contentsOf: line)
            } catch { failure = error }
        }
    }

    func finish(_ attempt: GestureAttempt, completion: @escaping @MainActor @Sendable (Result<URL, Error>) -> Void) {
        append(RecordingLogEntry(kind: "end", attempt: attempt))
        queue.async { [self] in
            let result: Result<URL, Error>
            do {
                defer { try? handle.close() }
                if let failure { throw failure }
                try handle.synchronize()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(attempt).write(to: summaryURL, options: .atomic)
                result = .success(dataURL)
            } catch { result = .failure(error) }
            // AppKit waits in a nested run loop for terminateLater. A quit
            // invoked from a main-queue block prevents that queue from being
            // drained again, so deliver completion through the run loop.
            let mainLoop = CFRunLoopGetMain()
            CFRunLoopPerformBlock(mainLoop, CFRunLoopMode.commonModes.rawValue) {
                MainActor.assumeIsolated { completion(result) }
            }
            CFRunLoopWakeUp(mainLoop)
        }
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Trackcard/Gesture Recordings", isDirectory: true)
    }

    static func attempts(in directory: URL) -> [GestureAttempt] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" && $0.lastPathComponent != "annotations.json" }.compactMap {
            guard let data = try? Data(contentsOf: $0) else { return nil }
            return try? JSONDecoder().decode(GestureAttempt.self, from: data)
        }.sorted { $0.startedAt > $1.startedAt }
    }
}

final class GestureAnnotationStore: @unchecked Sendable {
    private let directory: URL
    private let queue = DispatchQueue(label: "trackcard.gesture-annotations", qos: .utility)
    private var url: URL { directory.appendingPathComponent("annotations.json") }

    init(directory: URL) { self.directory = directory }

    func load() throws -> GestureAnnotations {
        guard FileManager.default.fileExists(atPath: url.path) else { return GestureAnnotations() }
        return try JSONDecoder().decode(GestureAnnotations.self, from: Data(contentsOf: url))
    }

    func save(_ annotations: GestureAnnotations, completion: @escaping @MainActor @Sendable (Error?) -> Void) {
        queue.async { [self] in
            let failure: Error?
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(annotations).write(to: url, options: .atomic)
                failure = nil
            } catch { failure = error }
            let mainLoop = CFRunLoopGetMain()
            CFRunLoopPerformBlock(mainLoop, CFRunLoopMode.commonModes.rawValue) {
                MainActor.assumeIsolated { completion(failure) }
            }
            CFRunLoopWakeUp(mainLoop)
        }
    }
}
