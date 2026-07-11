// AnimatedEnemy.swift - A live animated creature placed in the world: its
// skeleton animator, the deformable meshes it writes into each frame, and its
// world-placement transform (scale · yaw · translate onto the terrain).
import NanosaurSkeleton
import QD3DMath

public struct AnimatedEnemy {
    public let instance: SkeletonInstance
    public let render: RenderableModel
    public let baseTransform: Matrix4x4

    public init(instance: SkeletonInstance, render: RenderableModel, baseTransform: Matrix4x4) {
        self.instance = instance
        self.render = render
        self.baseTransform = baseTransform
    }
}
