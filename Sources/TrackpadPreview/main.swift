import AppKit
import Foundation

// A bounded diagnostic uses the exact same bridge as the app, without opening
// windows, saving contact data, or requesting global keyboard/mouse access.
if CommandLine.arguments.contains("--diagnose") {
    MainActor.assumeIsolated {
        let capture = TrackpadCapture()
        defer { capture.close() }
        if let error = capture.error {
            print("Capture unavailable: \(error)")
            exit(1)
        }
        let devices = capture.refresh()
        for device in devices {
            print(String(format: "%@: %.2f × %.2f mm, %@, color %@", device.name,
                         device.sizeMM.width, device.sizeMM.height,
                         device.builtIn ? "built-in" : "external", device.color == nil ? "fallback" : "reported"))
        }
        var totalFrames = 0
        var maximumContacts = 0
        let end = ProcessInfo.processInfo.systemUptime + 3
        while ProcessInfo.processInfo.systemUptime < end {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 1 / 120))
            for device in devices {
                if let frame = capture.frame(for: device.id) {
                    totalFrames += 1
                    maximumContacts = max(maximumContacts, frame.contacts.filter(\.isTouching).count)
                }
            }
        }
        print("\(devices.count) trackpad(s), \(totalFrames) frame snapshots, maximum \(maximumContacts) active contact(s).")
        if devices.isEmpty { exit(2) }
    }
} else {
    let arguments = CommandLine.arguments
    func optionValue(_ option: String) -> String? {
        guard let index = arguments.firstIndex(of: option) else { return nil }
        guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
            fputs("\(option) requires a value.\n", stderr)
            exit(64)
        }
        return arguments[index + 1]
    }
    let snapshotPath = optionValue("--snapshot")
    let delayText = optionValue("--snapshot-delay") ?? "1"
    guard let delay = Double(delayText), delay.isFinite, (0...60).contains(delay) else {
        fputs("--snapshot-delay must be between 0 and 60 seconds.\n", stderr)
        exit(64)
    }
    if (snapshotPath != nil && !arguments.contains("--demo")) ||
       (arguments.contains("--snapshot-delay") && snapshotPath == nil) {
        fputs("Use --demo --snapshot <path.png> [--snapshot-delay <seconds>].\n", stderr)
        exit(64)
    }
    let app = NSApplication.shared
    let delegate = AppDelegate(snapshotURL: snapshotPath.map { URL(fileURLWithPath: $0) }, snapshotDelay: delay)
    app.delegate = delegate
    app.run()
}
