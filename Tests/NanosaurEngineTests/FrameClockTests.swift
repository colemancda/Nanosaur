import Testing

@testable import NanosaurEngine

private func approx(_ a: Float, _ b: Float, _ tol: Float = 1e-3) -> Bool { abs(a - b) < tol }

@Test func normalFrameRateComputes() {
    var clock = FrameClock()
    // 1,000,000 ticks/sec, 16,667 ticks elapsed -> ~60 fps.
    clock.update(deltaTicks: 16_667, frequency: 1_000_000)
    #expect(approx(clock.framesPerSecond, 60, 0.1))
    #expect(approx(clock.framesPerSecondFrac, 1.0 / clock.framesPerSecond))
}

@Test func zeroDeltaClampsToMin() {
    var clock = FrameClock(minFPS: 4, maxFPS: 500)
    clock.update(deltaTicks: 0, frequency: 1_000_000)
    #expect(clock.framesPerSecond == 4)
    #expect(approx(clock.framesPerSecondFrac, 0.25))
}

@Test func fastFrameClampsToMax() {
    var clock = FrameClock(minFPS: 4, maxFPS: 500)
    // 1 tick elapsed -> 1,000,000 fps, clamped to 500.
    clock.update(deltaTicks: 1, frequency: 1_000_000)
    #expect(clock.framesPerSecond == 500)
    #expect(approx(clock.framesPerSecondFrac, 1.0 / 500))
}

@Test func slowFrameClampsToMin() {
    var clock = FrameClock(minFPS: 4, maxFPS: 500)
    // 0.5s elapsed -> 2 fps, clamped up to the 4 fps floor.
    clock.update(deltaTicks: 500_000, frequency: 1_000_000)
    #expect(clock.framesPerSecond == 4)
}

@Test func fracIsAlwaysReciprocal() {
    var clock = FrameClock()
    for delta: UInt64 in [1, 100, 16_667, 33_333, 1_000_000, 10_000_000] {
        clock.update(deltaTicks: delta, frequency: 1_000_000)
        #expect(approx(clock.framesPerSecondFrac, 1.0 / clock.framesPerSecond))
    }
}
