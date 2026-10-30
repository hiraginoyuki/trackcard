import Foundation
import CoreGraphics

public struct VelocityTiltFeatures: Sendable {
    public let angularVelocity: Double
    public let radialVelocity: Double
    public let tangentialVelocity: Double
    public let pinchConfidence: Double
    public let path: PositionPathFeatures?
    public let velocityAlignment: Double?
    public let relativeShare: Double
    public let commonSpeed: Double
    public let speedBalance: Double
    public let thumbCandidateID: Int32?
    public let thumbRelativeAngle: Double?
    public let thumbAxisVelocity: Double?
    public let thumbRelativeVelocity: Double?
    public let confidence: Double
}

/// Causal relative-velocity decomposition. Ellipse axes are modulo pi, and
/// the larger initial patch is a candidate role, never an anatomical label.
struct VelocityTiltEvidence: Sendable {
    private var previous: [TransformContact] = []
    private var lastTime: TimeInterval?
    private var velocities = [CGPoint.zero, CGPoint.zero]
    private var areas: [[Double]] = [[], []]
    private var candidate: Int?
    private var lastAxis: Double?
    private var axisVelocity: Double?
    private var paths = PositionPathEvidence()

    mutating func receive(_ contacts: [TransformContact], at time: TimeInterval, useAxis: Bool,
                          usePaths: Bool = false) -> VelocityTiltFeatures? {
        defer { previous = contacts; lastTime = time }
        guard contacts.count == 2 else { return nil }
        for index in 0..<2 where areas[index].count < 3 {
            if let radii = contacts[index].radiiMM, radii.width > 0, radii.height > 0 {
                areas[index].append(radii.width * radii.height)
            }
        }
        if candidate == nil, areas.allSatisfy({ $0.count == 3 }) {
            candidate = areas[0].sorted()[1] >= areas[1].sorted()[1] ? 0 : 1
            lastAxis = nil
        }
        let q = CGPoint(x: contacts[1].positionMM.x - contacts[0].positionMM.x,
                        y: contacts[1].positionMM.y - contacts[0].positionMM.y)
        let span = hypot(q.x, q.y)
        let pairAngle = atan2(q.y, q.x)
        let axis: Double? = candidate.flatMap { index in
            guard let radii = contacts[index].radiiMM, let angle = contacts[index].orientation,
                  angle.isFinite, radii.width.isFinite, radii.height.isFinite,
                  abs(radii.width - radii.height) / max(radii.width, radii.height, 0.001) >= 0.15 else { return nil }
            return angle
        }
        guard previous.count == 2, let lastTime, time > lastTime, time - lastTime <= 0.05, span >= 2 else {
            if usePaths { _ = paths.receive(contacts, at: time, angularVelocity: 0) }
            velocities = [.zero, .zero]; lastAxis = axis; axisVelocity = nil
            return nil
        }
        let dt = time - lastTime
        let blend = 1 - exp(-dt / 0.024)
        for index in 0..<2 {
            let raw = CGPoint(x: (contacts[index].positionMM.x - previous[index].positionMM.x) / dt,
                              y: (contacts[index].positionMM.y - previous[index].positionMM.y) / dt)
            velocities[index].x += (raw.x - velocities[index].x) * blend
            velocities[index].y += (raw.y - velocities[index].y) * blend
        }
        let relative = CGPoint(x: velocities[1].x - velocities[0].x, y: velocities[1].y - velocities[0].y)
        let relativeSpeed = hypot(relative.x, relative.y)
        let commonSpeed = hypot((velocities[1].x + velocities[0].x) / 2, (velocities[1].y + velocities[0].y) / 2)
        let tangent = (q.x * relative.y - q.y * relative.x) / span
        let radial = (q.x * relative.x + q.y * relative.y) / span
        let omega = tangent / span
        let pathFeatures = usePaths ? paths.receive(contacts, at: time, angularVelocity: omega) : nil
        let share = relativeSpeed / max(0.001, relativeSpeed + 2 * commonSpeed)
        let speeds = velocities.map { hypot($0.x, $0.y) }
        let speedBalance = min(speeds[0], speeds[1]) / max(0.001, max(speeds[0], speeds[1]))
        let alignment: Double? = speeds.allSatisfy { $0 >= 3 } ?
            min(1, max(-1, (velocities[0].x * velocities[1].x + velocities[0].y * velocities[1].y) / (speeds[0] * speeds[1]))) : nil
        let coordination = min(1, share / 0.45) *
            (alignment.map { 0.35 + 0.65 * (1 - $0) / 2 } ?? 1)
        let pinchConfidence = min(1, abs(radial) / 12) *
            min(1, abs(radial) / max(3, relativeSpeed)) * coordination
        var confidence = min(1, abs(omega) / (12 * .pi / 180)) *
            min(1, abs(tangent) / max(3, relativeSpeed)) * coordination
        if let axis, let lastAxis {
            let difference = 0.5 * atan2(sin(2 * (axis - lastAxis)), cos(2 * (axis - lastAxis)))
            let rate = difference / dt
            axisVelocity = (axisVelocity ?? rate) + (rate - (axisVelocity ?? rate)) * blend
        } else { axisVelocity = nil }
        lastAxis = axis
        if useAxis, let axisVelocity, abs(omega) > 0.01 {
            let support = axisVelocity * omega > 0 ? min(1, abs(axisVelocity / omega)) : 0
            confidence *= 0.85 + 0.15 * support
        }
        return VelocityTiltFeatures(angularVelocity: omega, radialVelocity: radial,
            tangentialVelocity: tangent, pinchConfidence: pinchConfidence, path: pathFeatures, velocityAlignment: alignment,
            relativeShare: share, commonSpeed: commonSpeed, speedBalance: speedBalance,
            thumbCandidateID: candidate.map { contacts[$0].id },
            thumbRelativeAngle: axis.map { 0.5 * atan2(sin(2 * ($0 - pairAngle)), cos(2 * ($0 - pairAngle))) },
            thumbAxisVelocity: axisVelocity, thumbRelativeVelocity: axisVelocity.map { $0 - omega }, confidence: confidence)
    }
}
