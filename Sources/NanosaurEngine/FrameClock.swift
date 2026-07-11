// FrameClock.swift - Frame-rate timing, ported from QD3D_CalcFramesPerSecond
// (src/QD3D/QD3D_Support.c). Every per-second rate in the game is multiplied by
// `framesPerSecondFrac` (= 1/FPS) to get its per-frame delta, so motion is
// frame-rate independent. FPS is clamped to [minFPS, maxFPS]: below the floor
// physics/collision would tunnel through solids; above the ceiling the deltas
// underflow float precision (see the Pangea book, Ch.7).
//
// The clamp math here is pure and testable; the SDL performance-counter reads
// and the busy-wait that actually enforces maxFPS live in the app loop.

public struct FrameClock: Sendable {
    /// MIN_FPS / MAX_FPS from qd3d_support.h.
    public let minFPS: Float
    public let maxFPS: Float

    public private(set) var framesPerSecond: Float
    public private(set) var framesPerSecondFrac: Float

    public init(minFPS: Float = 4, maxFPS: Float = 500) {
        self.minFPS = minFPS
        self.maxFPS = maxFPS
        self.framesPerSecond = minFPS
        self.framesPerSecondFrac = 1 / minFPS
    }

    /// Recompute FPS from the elapsed high-resolution ticks since the previous
    /// frame. `frequency` is the counter's ticks-per-second
    /// (SDL_GetPerformanceFrequency).
    public mutating func update(deltaTicks: UInt64, frequency: UInt64) {
        var fps: Float
        if deltaTicks == 0 || frequency == 0 {
            fps = minFPS // avoid divide-by-zero
        } else {
            fps = Float(frequency) / Float(deltaTicks)
            if fps > maxFPS { fps = maxFPS }
            if fps < minFPS { fps = minFPS }
        }
        framesPerSecond = fps
        framesPerSecondFrac = 1 / fps
    }
}
