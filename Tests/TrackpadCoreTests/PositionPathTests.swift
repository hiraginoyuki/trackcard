import CoreGraphics
import Testing
@testable import TrackpadCore

private func pathPair(span: Double = 40, turn: Double = 0, axis: Double = 0,
                      offset: CGPoint = .zero, pivot: Bool = false) -> [TransformContact] {
    let q = CGPoint(x: span * cos(turn), y: span * sin(turn))
    return [TransformContact(id: 1, positionMM: CGPoint(x: offset.x - (pivot ? 0 : q.x / 2),
                                                     y: offset.y - (pivot ? 0 : q.y / 2)),
                             orientation: axis, radiiMM: CGSize(width: 9, height: 4)),
            TransformContact(id: 2, positionMM: CGPoint(x: offset.x + (pivot ? q.x : q.x / 2),
                                                       y: offset.y + (pivot ? q.y : q.y / 2)),
                             orientation: axis, radiiMM: CGSize(width: 6, height: 4))]
}

@Test func circularRelativePathsSupplyCurvatureWithAStationaryPivot() throws {
    for direction in [-1.0, 1.0] {
        var evidence = VelocityTiltEvidence()
        var features: VelocityTiltFeatures?
        for index in 0...8 {
            features = evidence.receive(pathPair(turn: direction * Double(index) * 4 * .pi / 180, pivot: true),
                                        at: Double(index) * 0.015, useAxis: false, usePaths: true)
        }
        let path = try #require(features?.path)
        let curvature = try #require(path.relativeCurvature)
        #expect(curvature * direction > 0)
        #expect(abs(curvature) * 40 > 0.7 && abs(curvature) * 40 < 1.4)
        #expect(path.rotationSupport > 0.8 && path.relativeTravel > 3)
        #expect(path.contactCurvatures[0] == nil && path.contactCurvatures[1] != nil)
    }
}

@Test func straightPinchPathsHaveNoInventedCurvature() throws {
    var evidence = VelocityTiltEvidence()
    var features: VelocityTiltFeatures?
    for index in 0...8 {
        features = evidence.receive(pathPair(span: 40 + Double(index) * 2), at: Double(index) * 0.015,
                                    useAxis: false, usePaths: true)
    }
    let path = try #require(features?.path)
    #expect(abs(try #require(path.relativeCurvature)) < 1e-9)
    #expect(path.rotationSupport == 0 && path.relativeTravel > 3)
}

@Test func insufficientTravelAndSubmillimetreJitterCannotEstablishCurvature() throws {
    var evidence = VelocityTiltEvidence()
    var features: VelocityTiltFeatures?
    for index in 0...20 {
        features = evidence.receive(pathPair(span: 40 + (index.isMultiple(of: 2) ? 0.04 : -0.04)),
                                    at: Double(index) * 0.01, useAxis: false, usePaths: true)
    }
    let path = try #require(features?.path)
    #expect(path.relativeCurvature == nil && path.rotationSupport == 0)
}


@Test func curvatureIsInvariantToTrackpadPositionAndDropsHistoryAfterAGap() throws {
    var local = PositionPathEvidence(), shifted = PositionPathEvidence()
    var a: PositionPathFeatures?, b: PositionPathFeatures?
    for index in 0...8 {
        let angle = Double(index) * 4 * .pi / 180
        a = local.receive(pathPair(turn: angle), at: Double(index) * 0.015, angularVelocity: 1)
        b = shifted.receive(pathPair(turn: angle, offset: CGPoint(x: 1000, y: -1000)),
                            at: Double(index) * 0.015, angularVelocity: 1)
    }
    #expect(abs(try #require(a?.relativeCurvature) - #require(b?.relativeCurvature)) < 1e-9)
    #expect(local.receive(pathPair(turn: 2), at: 1, angularVelocity: 1) == nil)
    let fresh = local.receive(pathPair(turn: 2.01), at: 1.015, angularVelocity: 1)
    #expect(fresh?.relativeCurvature == nil && fresh?.rotationSupport == 0)
}
