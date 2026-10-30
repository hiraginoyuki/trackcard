import QuartzCore

@MainActor
enum PreviewAnimation {
    static let timingFunction = CAMediaTimingFunction(controlPoints: 0.26, 0, 0.24, 1)
}
