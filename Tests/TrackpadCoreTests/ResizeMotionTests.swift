import Testing
@testable import TrackpadCore

@Test func resizeResponseMatchesAcrossDisplayRefreshRates() {
    func result(hz: Int) -> Double {
        var motion = ResizeMotion(scale: 0.5)
        motion.reset(to: 0.5, at: 0)
        motion.retarget(to: 0.8)
        for frame in 1...(hz / 20) { motion.advance(at: Double(frame) / Double(hz)) }
        return motion.scale
    }
    #expect(abs(result(hz: 60) - result(hz: 120)) < 0.000001)
    #expect(abs(result(hz: 120) - result(hz: 240)) < 0.000001)
}

@Test func resizeStartsGentlyAndSettlesPromptlyWithoutOvershoot() {
    var motion = ResizeMotion(scale: 0.5)
    motion.reset(to: 0.5, at: 0)
    motion.retarget(to: 0.8)
    motion.advance(at: 1 / 120)
    let first = motion.scale
    #expect(first > 0.5 && first < 0.6)
    motion.advance(at: 2 / 120)
    #expect(motion.scale - first > first - 0.5)
    motion.advance(at: 6 / 120)
    #expect(motion.scale > 0.77 && motion.scale < 0.8)
    for frame in 7...30 {
        motion.advance(at: Double(frame) / 120)
        #expect(motion.scale <= 0.8)
    }
    #expect(motion.scale == 0.8 && motion.velocity == 0)
}

@Test func resizeRetargetsWithContinuousVelocityAndReversesPromptly() {
    var motion = ResizeMotion(scale: 0.5)
    motion.reset(to: 0.5, at: 0)
    motion.retarget(to: 0.8)
    motion.advance(at: 1 / 120)
    let before = motion.scale
    let velocity = motion.velocity
    motion.retarget(to: 0.3)
    #expect(motion.scale == before && motion.velocity == velocity)
    motion.advance(at: 2 / 120)
    #expect(motion.scale < before + 0.001 && motion.velocity < 0)
    motion.advance(at: 3 / 120)
    #expect(motion.scale < before && motion.scale > 0.3)
    for frame in 4...30 {
        motion.advance(at: Double(frame) / 120)
        #expect(motion.scale >= 0.3)
    }
    #expect(motion.scale == 0.3 && motion.velocity == 0)
}

@Test func reduceMotionAndLongInterruptionsStopTheResizeSpring() {
    var motion = ResizeMotion(scale: 0.5)
    motion.reset(to: 0.5, at: 0)
    motion.retarget(to: 0.8)
    motion.advance(at: 1 / 120, reduceMotion: true)
    #expect(motion.scale == 0.8 && motion.velocity == 0)
    motion.retarget(to: 0.4)
    motion.advance(at: 2)
    #expect(motion.scale == 0.4 && motion.velocity == 0)
}

@Test func contactNoiseIsAttenuatedWhileTheTargetRemainsExact() {
    var motion = ResizeMotion(scale: 0.5)
    motion.reset(to: 0.5, at: 0)
    var minimum = 1.0
    var maximum = 0.0
    for frame in 1...30 {
        motion.retarget(to: frame.isMultiple(of: 2) ? 0.5004 : 0.4996)
        motion.advance(at: Double(frame) / 120)
        if frame > 10 {
            minimum = min(minimum, motion.scale)
            maximum = max(maximum, motion.scale)
        }
    }
    #expect(maximum - minimum < 0.0004)
    #expect(motion.target == 0.5004)
}

@Test func invalidOrNonmonotonicResizeValuesCannotPoisonTheMotion() {
    var motion = ResizeMotion(scale: 0.5)
    motion.reset(to: 0.5, at: 1)
    motion.retarget(to: .nan)
    motion.retarget(to: -1)
    motion.reset(to: .infinity)
    motion.advance(at: .nan)
    motion.advance(at: 0)
    #expect(motion.scale == 0.5 && motion.target == 0.5)
    motion.retarget(to: 0.8)
    motion.advance(at: 1)
    #expect(motion.scale == 0.5)
    motion.advance(at: 1.01)
    #expect(motion.scale > 0.5 && motion.scale < 0.8)
}
