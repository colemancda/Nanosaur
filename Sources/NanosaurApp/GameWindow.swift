// GameWindow.swift - Opens the SDL3 window + OpenGL context and runs the main
// loop, ported from the SDL/GL setup in src/Boot.cpp and the loop in
// src/System/Main.c. This is the seam where the pure-Swift engine meets the
// windowing/GL C libraries.
//
// The loop mirrors the original: each frame recompute the frame rate (with the
// MAX_FPS busy-wait cap), pump SDL events, run MoveObjects, then clear and swap
// the GL buffers. Rendering of actual geometry is filled in as the renderer
// layer is ported; for now the loop stands up a window and clears it.
import Foundation
import CSDL3
import COpenGL
import NanosaurEngine
import QD3DMath

public enum GameWindowError: Error {
    case sdlInitFailed(String)
    case windowCreationFailed(String)
    case glContextFailed(String)
}

// SDL3's SDL_UINT64_C(...) flag macros don't import into Swift, so mirror the
// literal values from SDL_init.h / SDL_video.h.
private let kInitVideo: UInt32 = 0x0000_0020
private let kWindowOpenGL: UInt64 = 0x0000_0000_0000_0002
private let kWindowResizable: UInt64 = 0x0000_0000_0000_0020
private let kWindowHighPixelDensity: UInt64 = 0x0000_0000_0000_2000
private let kGLContextProfileCompatibility: Int32 = 0x0002

public final class GameWindow {
    public let window: OpaquePointer
    public let glContext: SDL_GLContext
    private let performanceFrequency: UInt64
    private var previousCounter: UInt64
    public private(set) var clock = FrameClock()

    public let objects = ObjectManager()

    /// Meshes to display (temporary model-viewer scene while the full engine is
    /// ported - the camera auto-frames them and they slowly spin).
    public var renderables: [RenderableMesh] = []
    private let renderer = Renderer()
    private var spin: Float = 0
    private let viewportWidth: Int32
    private let viewportHeight: Int32

    /// Initial virtual window size (the game's classic 640x480 design size).
    public init(title: String = "Nanosaur", width: Int32 = 640, height: Int32 = 480) throws {
        viewportWidth = width
        viewportHeight = height
        guard SDL_Init(SDL_InitFlags(kInitVideo)) else {
            throw GameWindowError.sdlInitFailed(String(cString: SDL_GetError()))
        }

        // Request a GL 2.0 compatibility-profile, double-buffered, 32-bit-depth
        // context (matches Boot.cpp / the Pangea-book render setup).
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, kGLContextProfileCompatibility)
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 2)
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 0)
        SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1)
        SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, 24)

        let flags = SDL_WindowFlags(kWindowOpenGL | kWindowResizable | kWindowHighPixelDensity)
        guard let window = title.withCString({ SDL_CreateWindow($0, width, height, flags) }) else {
            let err = String(cString: SDL_GetError())
            SDL_Quit()
            throw GameWindowError.windowCreationFailed(err)
        }
        self.window = window

        guard let glContext = SDL_GL_CreateContext(window) else {
            let err = String(cString: SDL_GetError())
            SDL_DestroyWindow(window)
            SDL_Quit()
            throw GameWindowError.glContextFailed(err)
        }
        self.glContext = glContext

        _ = SDL_GL_MakeCurrent(window, glContext)
        _ = SDL_GL_SetSwapInterval(1) // vsync

        performanceFrequency = SDL_GetPerformanceFrequency()
        previousCounter = SDL_GetPerformanceCounter()

        glViewport(0, 0, width, height)
        glEnable(GLenum(GL_DEPTH_TEST))
        renderer.enableBasicLighting()
        glClearColor(0, 0, 0.15, 1)
    }

    deinit {
        SDL_GL_DestroyContext(glContext)
        SDL_DestroyWindow(window)
        SDL_Quit()
    }

    /// Recompute the frame clock, busy-waiting/sleeping to enforce the MAX_FPS
    /// ceiling exactly like QD3D_CalcFramesPerSecond.
    private func tickFrameClock() {
        while true {
            let now = SDL_GetPerformanceCounter()
            let delta = now &- previousCounter
            if delta > 0, performanceFrequency > 0 {
                let fps = Float(performanceFrequency) / Float(delta)
                if fps > clock.maxFPS {
                    if fps - clock.maxFPS > 1000 { SDL_Delay(1) }
                    continue // slow down
                }
            }
            clock.update(deltaTicks: delta, frequency: performanceFrequency)
            previousCounter = now
            return
        }
    }

    /// Renders one frame's contents (clear + future geometry). Factored out so
    /// both the live loop and the screenshot path share it.
    private func renderFrame() {
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT) | GLbitfield(GL_DEPTH_BUFFER_BIT))

        guard !renderables.isEmpty else { return }

        let (center, radius) = RenderableMesh.bounds(of: renderables)
        let aspect = Float(viewportWidth) / Float(viewportHeight)
        let eye = Point3D(x: center.x, y: center.y, z: center.z + radius * 3)
        renderer.setCamera(
            eye: eye, center: center, up: Vector3D(x: 0, y: 1, z: 0),
            aspect: aspect, near: max(0.1, radius * 0.05), far: radius * 10)

        spin += clock.framesPerSecondFrac // ~1 rad/sec

        // Spin the model about its own center.
        let model = Matrix4x4.translate(-center.x, -center.y, -center.z)
            .multiplied(by: .rotationY(spin))
            .multiplied(by: .translate(center.x, center.y, center.z))

        for mesh in renderables {
            renderer.draw(mesh, transform: model)
        }
    }

    /// Reads the current color buffer and writes it as a binary PPM (P6). Used
    /// for headless smoke tests / screenshots (glReadPixels is core GL, so this
    /// works even on a surfaceless/offscreen context where SwapWindow can't).
    public func writeScreenshotPPM(to path: String, width: Int32 = 640, height: Int32 = 480) {
        let w = Int(width), h = Int(height)
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        glPixelStorei(GLenum(GL_PACK_ALIGNMENT), 1)
        rgba.withUnsafeMutableBytes { buf in
            glReadPixels(0, 0, width, height, GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), buf.baseAddress)
        }
        // PPM is top-to-bottom; GL is bottom-to-top, so flip rows.
        var ppm = Data("P6\n\(w) \(h)\n255\n".utf8)
        for row in stride(from: h - 1, through: 0, by: -1) {
            for col in 0..<w {
                let i = (row * w + col) * 4
                ppm.append(rgba[i]); ppm.append(rgba[i + 1]); ppm.append(rgba[i + 2])
            }
        }
        try? ppm.write(to: URL(fileURLWithPath: path))
    }

    /// Runs the main loop until the window is closed. If `maxFrames` is given,
    /// stops after that many frames. If `screenshotPath` is given, captures the
    /// final frame and returns without swapping (headless-safe).
    public func run(maxFrames: Int? = nil, screenshotPath: String? = nil) {
        var running = true
        var frame = 0
        var event = SDL_Event()

        while running {
            tickFrameClock()

            while SDL_PollEvent(&event) {
                if event.type == SDL_EVENT_QUIT.rawValue {
                    running = false
                }
            }

            objects.moveObjects()
            renderFrame()

            frame += 1
            let lastFrame = maxFrames.map { frame >= $0 } ?? false

            if lastFrame, let screenshotPath {
                writeScreenshotPPM(to: screenshotPath)
                return // skip the swap: offscreen contexts may not support it
            }

            SDL_GL_SwapWindow(window)
            if lastFrame { running = false }
        }
    }
}
