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
import NanosaurSkeleton
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

    /// Model to display (temporary model-viewer scene while the full engine is
    /// ported - the camera auto-frames it and it slowly spins).
    public var model: RenderableModel?

    /// Animated skeleton to display: the deformer plus the render meshes it
    /// writes into each frame. Takes precedence over `model` when set.
    public var skeleton: (instance: SkeletonInstance, render: RenderableModel)?

    /// Terrain to fly over: the landscape mesh, its texture atlas (kept alive),
    /// and the player start. Takes precedence over everything else.
    public var terrain: (mesh: RenderableMesh, atlas: Texture2D, startX: Float, startZ: Float, startHeight: Float)?

    /// Scenery placed on the terrain: a shared model file plus per-item
    /// (object-index, world-transform) placements drawn over the landscape.
    public var scenery: (model: RenderableModel, placements: [(object: Int, transform: Matrix4x4)])?

    /// Animated enemies roaming the world: each has its own skeleton instance,
    /// deformable render meshes, and a world placement transform.
    public var enemies: [AnimatedEnemy] = []

    /// A keyboard-driven player character; when set, the camera chases it.
    public var player: PlayerController?
    /// Terrain height lookup for grounding the player.
    public var terrainHeight: ((Float, Float) -> Float)?
    /// The in-game infobar overlay.
    public var hud: HUD?

    private var flyOffset: Float = 0

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

    /// Maps the current SDL keyboard state to player input (WASD / arrows to
    /// move + turn, space to jet).
    private func readPlayerInput() -> PlayerInput {
        var input = PlayerInput()
        guard let kb = SDL_GetKeyboardState(nil) else { return input }
        func down(_ sc: SDL_Scancode) -> Bool { kb[Int(sc.rawValue)] }
        input.forward = down(SDL_SCANCODE_W) || down(SDL_SCANCODE_UP)
        input.back = down(SDL_SCANCODE_S) || down(SDL_SCANCODE_DOWN)
        input.left = down(SDL_SCANCODE_A) || down(SDL_SCANCODE_LEFT)
        input.right = down(SDL_SCANCODE_D) || down(SDL_SCANCODE_RIGHT)
        input.jet = down(SDL_SCANCODE_SPACE)
        return input
    }

    /// Renders one frame's contents (clear + future geometry). Factored out so
    /// both the live loop and the screenshot path share it.
    private func renderFrame() {
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT) | GLbitfield(GL_DEPTH_BUFFER_BIT))

        // Terrain scene: a driveable player if present, else an orbit/fly-over.
        if let terrain {
            let aspect = Float(viewportWidth) / Float(viewportHeight)
            let heightFn = terrainHeight ?? { _, _ in terrain.startHeight }

            if let player {
                // Update the player from the keyboard and chase-cam behind it.
                player.update(dt: clock.framesPerSecondFrac, input: readPlayerInput(), groundHeight: heightFn)
                let fwd = player.forwardDirection
                let eye = Point3D(x: player.position.x - fwd.x * 450,
                                  y: player.position.y + 280,
                                  z: player.position.z - fwd.z * 450)
                let look = Point3D(x: player.position.x + fwd.x * 250,
                                   y: player.position.y + 90,
                                   z: player.position.z + fwd.z * 250)
                renderer.setCamera(eye: eye, center: look, up: Vector3D(x: 0, y: 1, z: 0),
                                   aspect: aspect, fovYDegrees: 70, near: 20, far: 30000)
            } else {
                // Frame the herd: orbit slowly around the enemies' centroid.
                var focusX = terrain.startX, focusZ = terrain.startZ
                var focusY = terrain.startHeight + 150
                if !enemies.isEmpty {
                    var sx: Float = 0, sz: Float = 0, sy: Float = 0
                    for e in enemies {
                        sx += e.baseTransform.value[3][0]
                        sy += e.baseTransform.value[3][1]
                        sz += e.baseTransform.value[3][2]
                    }
                    let n = Float(enemies.count)
                    focusX = sx / n; focusY = sy / n + 150; focusZ = sz / n
                }
                flyOffset += clock.framesPerSecondFrac * 0.25 // slow orbit (radians)
                let radius: Float = 1600
                let eye = Point3D(x: focusX + cosf(flyOffset) * radius,
                                  y: focusY + 500,
                                  z: focusZ + sinf(flyOffset) * radius)
                renderer.setCamera(
                    eye: eye, center: Point3D(x: focusX, y: focusY, z: focusZ),
                    up: Vector3D(x: 0, y: 1, z: 0),
                    aspect: aspect, fovYDegrees: 70, near: 30, far: 30000)
            }
            renderer.draw(terrain.mesh, transform: .identity)

            // Scenery: draw each placed item's meshes at its world transform.
            if let scenery {
                for placement in scenery.placements where placement.object < scenery.model.objects.count {
                    for meshIndex in scenery.model.objects[placement.object] {
                        renderer.draw(scenery.model.meshes[meshIndex], transform: placement.transform)
                    }
                }
            }

            // Enemies: deform each skeleton into world space and draw it.
            for enemy in enemies {
                enemy.instance.update(dt: clock.framesPerSecondFrac, baseTransform: enemy.baseTransform)
                for (i, mesh) in enemy.render.meshes.enumerated() where i < enemy.instance.deformedPoints.count {
                    mesh.updateGeometry(points: enemy.instance.deformedPoints[i],
                                        normals: enemy.instance.deformedNormals[i])
                }
                for mesh in enemy.render.meshes { renderer.draw(mesh, transform: .identity) }
            }

            // Player: its deformed geometry was updated above; draw it.
            if let player {
                for (i, mesh) in player.render.meshes.enumerated() where i < player.instance.deformedPoints.count {
                    mesh.updateGeometry(points: player.instance.deformedPoints[i],
                                        normals: player.instance.deformedNormals[i])
                }
                for mesh in player.render.meshes { renderer.draw(mesh, transform: .identity) }
            }

            // HUD overlay (infobar) drawn last, over the 3D scene.
            hud?.draw(with: renderer)
            return
        }

        // Animated skeleton: deform, push geometry into the render meshes, and
        // draw with an identity transform (deformed points are world-space).
        if let skeleton {
            skeleton.instance.update(dt: clock.framesPerSecondFrac)
            for (i, mesh) in skeleton.render.meshes.enumerated() where i < skeleton.instance.deformedPoints.count {
                mesh.updateGeometry(points: skeleton.instance.deformedPoints[i],
                                    normals: skeleton.instance.deformedNormals[i])
            }
            frameCameraOnDeformed(skeleton.instance.deformedPoints)
            for mesh in skeleton.render.meshes { renderer.draw(mesh, transform: .identity) }
            return
        }

        guard let model, !model.meshes.isEmpty else { return }

        let center = frameCamera(on: model.meshes)
        spin += clock.framesPerSecondFrac // ~1 rad/sec

        // Spin the model about its own center.
        let transform = Matrix4x4.translate(-center.x, -center.y, -center.z)
            .multiplied(by: .rotationY(spin))
            .multiplied(by: .translate(center.x, center.y, center.z))
        for mesh in model.meshes { renderer.draw(mesh, transform: transform) }
    }

    /// Frame the camera on the meshes from a 3/4 profile (weighted along X so
    /// long models like the Rex aren't viewed end-on). Returns the center.
    @discardableResult
    private func frameCamera(on meshes: [RenderableMesh]) -> Point3D {
        let (center, radius) = RenderableMesh.bounds(of: meshes)
        let aspect = Float(viewportWidth) / Float(viewportHeight)
        let distance = radius * 1.6
        let dir = Vector3D(x: 1, y: 0.35, z: 0.5).normalized()
        let eye = Point3D(x: center.x + dir.x * distance,
                          y: center.y + dir.y * distance,
                          z: center.z + dir.z * distance)
        renderer.setCamera(
            eye: eye, center: center, up: Vector3D(x: 0, y: 1, z: 0),
            aspect: aspect, near: max(1, radius * 0.1), far: distance + radius * 4)
        return center
    }

    /// Frame the camera on live deformed geometry (world-space float triples),
    /// so an animated skeleton stays centered as its pose changes.
    private func frameCameraOnDeformed(_ meshes: [[Float]]) {
        var lo = Point3D(x: .greatestFiniteMagnitude, y: .greatestFiniteMagnitude, z: .greatestFiniteMagnitude)
        var hi = Point3D(x: -.greatestFiniteMagnitude, y: -.greatestFiniteMagnitude, z: -.greatestFiniteMagnitude)
        for mesh in meshes {
            var i = 0
            while i + 2 < mesh.count {
                lo.x = min(lo.x, mesh[i]); hi.x = max(hi.x, mesh[i])
                lo.y = min(lo.y, mesh[i + 1]); hi.y = max(hi.y, mesh[i + 1])
                lo.z = min(lo.z, mesh[i + 2]); hi.z = max(hi.z, mesh[i + 2])
                i += 3
            }
        }
        guard lo.x <= hi.x else { return }
        let center = Point3D(x: (lo.x + hi.x) / 2, y: (lo.y + hi.y) / 2, z: (lo.z + hi.z) / 2)
        let dx = hi.x - lo.x, dy = hi.y - lo.y, dz = hi.z - lo.z
        let radius = max(1, (dx * dx + dy * dy + dz * dz).squareRoot() / 2)
        let aspect = Float(viewportWidth) / Float(viewportHeight)
        let distance = radius * 1.6
        let dir = Vector3D(x: 1, y: 0.35, z: 0.5).normalized()
        let eye = Point3D(x: center.x + dir.x * distance, y: center.y + dir.y * distance, z: center.z + dir.z * distance)
        renderer.setCamera(
            eye: eye, center: center, up: Vector3D(x: 0, y: 1, z: 0),
            aspect: aspect, near: max(1, radius * 0.1), far: distance + radius * 4)
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
