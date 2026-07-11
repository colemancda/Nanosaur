// PlayerController.swift - A keyboard-driven player character (the
// Deinonychus), a simplified port of the player logic in src/Player/MyGuy.c:
// turn, walk in the facing direction, jetpack up with gravity settling onto
// the terrain, and animate (walk when moving, stand when idle). Rendering and
// the follow-camera live in GameWindow.
import Foundation
import NanosaurSkeleton
import QD3DMath

/// Per-frame player input (already mapped from the keyboard by the window).
public struct PlayerInput {
    public var forward = false
    public var back = false
    public var left = false
    public var right = false
    public var jet = false
    public init() {}
}

public final class PlayerController {
    public var position: Point3D
    public var heading: Float = 0 // yaw radians
    public let instance: SkeletonInstance
    public let render: RenderableModel

    private let scale: Float
    private let walkAnim: Int
    private let standAnim: Int
    private var currentAnim = -1
    private var verticalVelocity: Float = 0

    // Tuned to feel like the original (player_control.h speeds).
    private let turnSpeed: Float = 2.6
    private let moveSpeed: Float = 550
    private let jetSpeed: Float = 700
    private let gravity: Float = 1600

    public init(model: SkeletonModel, render: RenderableModel, start: Point3D,
                scale: Float = 0.5, walkAnim: Int = 1, standAnim: Int = 0) {
        self.instance = SkeletonInstance(model: model, animNum: standAnim)
        self.render = render
        self.position = start
        self.scale = scale
        self.walkAnim = walkAnim
        self.standAnim = standAnim
    }

    /// The direction the player faces on the XZ plane.
    public var forwardDirection: Vector3D {
        Vector3D(x: sinf(heading), y: 0, z: cosf(heading))
    }

    public func update(dt: Float, input: PlayerInput, groundHeight: (Float, Float) -> Float) {
        if input.left { heading += turnSpeed * dt }
        if input.right { heading -= turnSpeed * dt }

        let fwd = forwardDirection
        var moving = false
        if input.forward {
            position.x += fwd.x * moveSpeed * dt; position.z += fwd.z * moveSpeed * dt; moving = true
        }
        if input.back {
            position.x -= fwd.x * moveSpeed * dt; position.z -= fwd.z * moveSpeed * dt; moving = true
        }

        // Vertical: jetpack thrust, gravity, and settling onto the ground.
        let ground = groundHeight(position.x, position.z)
        if input.jet { verticalVelocity = jetSpeed }
        verticalVelocity -= gravity * dt
        position.y += verticalVelocity * dt
        if position.y <= ground {
            position.y = ground
            verticalVelocity = 0
        }

        // Walk while moving, stand otherwise.
        let want = moving ? walkAnim : standAnim
        if want != currentAnim {
            instance.setAnim(want)
            currentAnim = want
        }

        let base = Matrix4x4.scale(scale, scale, scale)
            .multiplied(by: Matrix4x4.rotationY(heading))
            .multiplied(by: Matrix4x4.translate(position.x, position.y, position.z))
        instance.update(dt: dt, baseTransform: base)
    }
}
