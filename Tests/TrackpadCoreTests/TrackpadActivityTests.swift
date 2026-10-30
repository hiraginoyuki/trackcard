import Foundation
import CoreGraphics
import Testing
@testable import TrackpadCore

private func pair() -> TrackpadActivity {
    var activity = TrackpadActivity()
    activity.setDevices([11, 22])
    return activity
}

@Test func singleTrackpadStaysStacked() {
    var activity = TrackpadActivity()
    activity.setDevices([11])
    activity.receive(deviceID: 11, hasContact: true, at: 0)
    activity.evaluate(at: 30)
    #expect(activity.layout == .stacked)
    #expect(activity.frontID == 11)
}

@Test func aLaterTouchPromotesTheBackCard() {
    var activity = pair()
    activity.receive(deviceID: 11, hasContact: true, at: 0)
    activity.receive(deviceID: 11, hasContact: false, at: 0.1)
    activity.receive(deviceID: 22, hasContact: true, at: 2)
    #expect(activity.frontID == 22)
    #expect(activity.layout == .stacked)
}

@Test func switchingAtHalfASecondSpreads() {
    var activity = pair()
    activity.receive(deviceID: 11, hasContact: true, at: 0)
    activity.receive(deviceID: 11, hasContact: false, at: 0.1)
    activity.receive(deviceID: 22, hasContact: true, at: 0.5)
    #expect(activity.layout == .sideBySide)
}

@Test func switchingAfterHalfASecondDoesNotSpread() {
    var activity = pair()
    activity.receive(deviceID: 11, hasContact: true, at: 0)
    activity.receive(deviceID: 11, hasContact: false, at: 0.1)
    activity.receive(deviceID: 22, hasContact: true, at: 0.501)
    #expect(activity.layout == .stacked)
}

@Test func simultaneousHeldContactsSpreadEvenWithoutRecentFrames() {
    var activity = pair()
    activity.receive(deviceID: 11, hasContact: true, at: 0)
    activity.receive(deviceID: 22, hasContact: true, at: 10)
    activity.evaluate(at: 100)
    #expect(activity.layout == .sideBySide)
}

@Test func exactlyTwoSecondsOfExclusiveUseRestacks() {
    var activity = pair()
    activity.receive(deviceID: 11, hasContact: true, at: 0)
    activity.receive(deviceID: 22, hasContact: true, at: 0)
    activity.receive(deviceID: 11, hasContact: false, at: 1)
    activity.evaluate(at: 2.999)
    #expect(activity.layout == .sideBySide)
    activity.evaluate(at: 3)
    #expect(activity.layout == .stacked)
    #expect(activity.frontID == 22)
}

@Test func renewedSharedUseResetsTheExclusiveTimer() {
    var activity = pair()
    activity.receive(deviceID: 11, hasContact: true, at: 0)
    activity.receive(deviceID: 22, hasContact: true, at: 0)
    activity.receive(deviceID: 11, hasContact: false, at: 1)
    activity.receive(deviceID: 11, hasContact: true, at: 2.5)
    activity.receive(deviceID: 11, hasContact: false, at: 2.7)
    activity.evaluate(at: 4.699)
    #expect(activity.layout == .sideBySide)
    activity.evaluate(at: 4.7)
    #expect(activity.layout == .stacked)
}

@Test func releasingBothTrackpadsRestacksWithoutAnotherTap() {
    var activity = pair()
    activity.receive(deviceID: 11, hasContact: true, at: 0)
    activity.receive(deviceID: 22, hasContact: true, at: 0)
    activity.receive(deviceID: 11, hasContact: false, at: 0.1)
    activity.receive(deviceID: 22, hasContact: false, at: 0.2)
    activity.evaluate(at: 2.099)
    #expect(activity.layout == .sideBySide)
    activity.evaluate(at: 2.1)
    #expect(activity.layout == .stacked)
    #expect(activity.frontID == 22)
}

@Test func switchingTrackpadsDuringTheIdleCountdownRestartsTheTimer() {
    var activity = pair()
    activity.receive(deviceID: 11, hasContact: true, at: 0)
    activity.receive(deviceID: 22, hasContact: true, at: 0)
    activity.receive(deviceID: 11, hasContact: false, at: 0.1)
    activity.receive(deviceID: 22, hasContact: false, at: 0.2)
    activity.receive(deviceID: 11, hasContact: true, at: 1)
    activity.receive(deviceID: 11, hasContact: false, at: 1.1)
    activity.evaluate(at: 2.999)
    #expect(activity.layout == .sideBySide)
    activity.evaluate(at: 3)
    #expect(activity.layout == .stacked)
    #expect(activity.frontID == 11)
}

@Test func ongoingFramesDoNotFightOverTheFrontCard() {
    var activity = pair()
    activity.receive(deviceID: 11, hasContact: true, at: 0)
    activity.receive(deviceID: 22, hasContact: true, at: 1)
    activity.receive(deviceID: 11, hasContact: true, at: 1.01)
    #expect(activity.frontID == 22)
}

@Test func disconnectClearsContactsAndRecency() {
    var activity = pair()
    activity.receive(deviceID: 11, hasContact: true, at: 0)
    activity.receive(deviceID: 22, hasContact: true, at: 0)
    activity.setDevices([11])
    #expect(activity.layout == .stacked)
    #expect(activity.frontID == 11)
    activity.setDevices([11, 22])
    activity.evaluate(at: 0.1)
    #expect(activity.layout == .stacked)
}

@Test func unknownDevicesAndInvalidTimeAreIgnored() {
    var activity = pair()
    activity.receive(deviceID: 33, hasContact: true, at: 0)
    activity.receive(deviceID: 22, hasContact: true, at: .nan)
    #expect(activity.layout == .stacked)
    #expect(activity.frontID == 11)
}

@Test func physicalSizingUsesLogicalScreenGeometry() {
    // A 600 mm-wide monitor has 3000 physical pixels. Both display modes
    // must render the 120 mm trackpad at the same real-world size.
    let mm = CGSize(width: 600, height: 340)
    let surface = CGSize(width: 120, height: 75)
    let modeA = PhysicalGeometry.pointsPerMillimeter(screenPoints: CGSize(width: 1500, height: 850), screenMM: mm)
    let modeB = PhysicalGeometry.pointsPerMillimeter(screenPoints: CGSize(width: 2000, height: 1133.333333), screenMM: mm)
    let a = PhysicalGeometry.surfaceSize(millimeters: surface, pointsPerMM: modeA)
    let b = PhysicalGeometry.surfaceSize(millimeters: surface, pointsPerMM: modeB)
    #expect(abs(a.width / 1500 - 0.2) < 0.0001)
    #expect(abs(b.width / 2000 - 0.2) < 0.0001)
}

@Test func missingDisplayMeasurementsHaveAFiniteFallback() {
    let density = PhysicalGeometry.pointsPerMillimeter(screenPoints: CGSize(width: 2000, height: 1000), screenMM: .zero)
    #expect(density.width.isFinite)
    #expect(abs(density.width - 72 / 25.4) < 0.0001)
    let calibrated = PhysicalGeometry.surfaceSize(millimeters: CGSize(width: 100, height: 50), pointsPerMM: density, calibration: 1.1)
    let expected: CGFloat = 110.0 * 72.0 / 25.4
    #expect(abs(calibrated.width - expected) < 0.0001)
}
