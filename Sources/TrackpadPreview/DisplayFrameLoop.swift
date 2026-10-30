import AppKit
import QuartzCore

/// Coalesces background display pulses onto the main run loop. Cancellation
/// also invalidates deliveries that were already queued before stop/restart.
private final class DisplayFrameDelivery: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var pending = false
    private var lastPulse = ProcessInfo.processInfo.systemUptime
    private let deliver: @MainActor @Sendable (TimeInterval) -> Void

    init(deliver: @escaping @MainActor @Sendable (TimeInterval) -> Void) { self.deliver = deliver }

    @objc func frame(_ sender: CADisplayLink) {
        lock.lock()
        lastPulse = ProcessInfo.processInfo.systemUptime
        guard active, !pending else { lock.unlock(); return }
        pending = true
        lock.unlock()
        let mainLoop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(mainLoop, CFRunLoopMode.commonModes.rawValue) { [self] in
            lock.lock()
            pending = false
            let shouldDeliver = active
            lock.unlock()
            if shouldDeliver {
                MainActor.assumeIsolated { deliver(ProcessInfo.processInfo.systemUptime) }
            }
        }
        CFRunLoopWakeUp(mainLoop)
    }

    func isStalled(at time: TimeInterval, interval: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return active && time - lastPulse >= interval * 2
    }

    func cancel() {
        lock.lock()
        active = false
        lock.unlock()
    }
}

private final class DisplayLinkThread: Thread, @unchecked Sendable {
    private let link: CADisplayLink
    private let lock = NSLock()
    private var workerRunLoop: CFRunLoop?
    private var stopping = false

    init(link: CADisplayLink) {
        self.link = link
        super.init()
        name = "Trackpad Preview Display"
        qualityOfService = .userInteractive
    }

    override func main() {
        autoreleasepool {
            let runLoop = CFRunLoopGetCurrent()
            lock.lock()
            workerRunLoop = runLoop
            let shouldStop = stopping
            lock.unlock()
            defer {
                link.invalidate()
                lock.lock()
                workerRunLoop = nil
                lock.unlock()
            }
            guard !shouldStop else { return }
            link.add(to: .current, forMode: .common)
            CFRunLoopRun()
        }
    }

    func stop() {
        lock.lock()
        stopping = true
        let runLoop = workerRunLoop
        lock.unlock()
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [self] in
            link.invalidate()
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        CFRunLoopWakeUp(runLoop)
    }
}

/// Follows the selected display, including ProMotion and tracking run loops.
/// CADisplayLink can wait synchronously on WindowServer during Mission Control
/// and Spaces animations. Keep that wait off the main thread; a common-mode
/// timer maintains updates at the display's maximum rate when pulses stall.
@MainActor
final class DisplayFrameLoop: NSObject {
    var onFrame: ((TimeInterval) -> Void)?
    private var worker: DisplayLinkThread?
    private var delivery: DisplayFrameDelivery?
    private var fallback: Timer?
    private var lastFrame: TimeInterval = -.infinity
    private var minimumInterval: TimeInterval = 0

    func start(on screen: NSScreen) {
        stop()
        let maximum = Float(max(1, screen.maximumFramesPerSecond))
        let interval = 1 / TimeInterval(maximum)
        minimumInterval = interval / 2
        lastFrame = -.infinity
        let delivery = DisplayFrameDelivery { [weak self] time in self?.frame(at: time) }
        let link = screen.displayLink(target: delivery, selector: #selector(DisplayFrameDelivery.frame(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: maximum, maximum: maximum, preferred: maximum)
        let worker = DisplayLinkThread(link: link)
        self.delivery = delivery
        self.worker = worker
        let fallback = Timer(timeInterval: interval, repeats: true) { [weak self, weak delivery] _ in
            MainActor.assumeIsolated {
                let time = ProcessInfo.processInfo.systemUptime
                guard delivery?.isStalled(at: time, interval: interval) == true else { return }
                self?.frame(at: time)
            }
        }
        fallback.tolerance = interval * 0.05
        RunLoop.main.add(fallback, forMode: .common)
        self.fallback = fallback
        worker.start()
    }

    func stop() {
        fallback?.invalidate()
        fallback = nil
        delivery?.cancel()
        delivery = nil
        worker?.stop()
        worker = nil
    }

    private func frame(at time: TimeInterval) {
        guard time - lastFrame >= minimumInterval else { return }
        lastFrame = time
        onFrame?(time)
    }
}
