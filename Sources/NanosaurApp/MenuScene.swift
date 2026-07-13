// MenuScene.swift - The main menu, ported from src/Screens/MainMenu.c. Five
// icons ride a carousel: the animated Deinonychus (start game) plus the
// Options, Info, Quit and HighScores models from MenuInterface.3dmf, arranged
// on a circle of radius WHEEL_SEPARATION and spun to bring the selection to the
// front. A reflection-mapped background sits behind them.
import Foundation
import NanosaurSkeleton
import QD3DFile
import QD3DMath
import SkeletonFile

public final class MenuScene {
    // MenuInterface.3dmf object indices (MainMenu.c).
    private enum Obj {
        static let quit = 0, options = 1, info = 2, highScores = 3, background = 5
    }

    private static let iconCount = 5
    private static let wheelSeparation: Float = 310
    private static let wheelCenterZ: Float = 0
    public static let spinSpeed: Float = 2.5

    /// Icon slot -> MenuInterface object. Slot 0 is the Deinonychus skeleton.
    private static let slotObjects = [Obj.options, Obj.info, Obj.quit, Obj.highScores]

    let model: RenderableModel
    let deinonInstance: SkeletonInstance
    let deinonRender: RenderableModel

    /// Carousel rotation; advancing by 2*PI/5 brings the next icon to the front.
    public var wheelRot: Float = 0

    // Menu camera (MainMenu.c): from (0,0,600) looking at the origin, fov 1 rad.
    public let cameraFrom = Point3D(x: 0, y: 0, z: 600)
    public let cameraTo = Point3D(x: 0, y: 0, z: 0)
    public let fovDegrees: Float = 57

    public init?(dataDir: String) {
        let fm = FileManager.default
        guard let md = fm.contents(atPath: "\(dataDir)/Models/MenuInterface.3dmf"),
              let menuFile = try? MetaFile3D(parsing3DMF: md),
              let dm = fm.contents(atPath: "\(dataDir)/Skeletons/Deinon.3dmf"),
              let deinonMeshFile = try? MetaFile3D(parsing3DMF: dm),
              let ds = fm.contents(atPath: "\(dataDir)/Skeletons/Deinon.skeleton.rsrc"),
              let deinonSkelFile = try? SkeletonFile(parsingResourceFork: ds)
        else { return nil }

        model = RenderableModel(menuFile)
        let deinonModel = SkeletonModel(meshFile: deinonMeshFile, skeletonFile: deinonSkelFile)
        deinonInstance = SkeletonInstance(model: deinonModel, animNum: 1)
        deinonInstance.animSpeed = 0.8
        deinonRender = RenderableModel(deinonMeshFile)
    }

    /// Where icon `slot` sits on the carousel this frame.
    private func iconPlacement(slot: Int) -> (rot: Float, x: Float, z: Float) {
        let r = wheelRot + (2 * .pi / Float(MenuScene.iconCount)) * Float(slot)
        return (r,
                sinf(r) * MenuScene.wheelSeparation,
                MenuScene.wheelCenterZ + (cosf(r) * MenuScene.wheelSeparation - 5))
    }

    /// The Deinonychus (slot 0) world transform, scale 0.8.
    public var deinonTransform: Matrix4x4 {
        let p = iconPlacement(slot: 0)
        return Matrix4x4.scale(0.8, 0.8, 0.8)
            .multiplied(by: Matrix4x4.rotationY(p.rot))
            .multiplied(by: Matrix4x4.translate(p.x, 0, p.z))
    }

    /// The four model icons (slots 1...4), as (object index, transform).
    public var iconTransforms: [(object: Int, transform: Matrix4x4)] {
        (1...4).map { slot in
            let p = iconPlacement(slot: slot)
            let t = Matrix4x4.rotationY(p.rot)
                .multiplied(by: Matrix4x4.translate(p.x, 0, p.z))
            return (MenuScene.slotObjects[slot - 1], t)
        }
    }

    /// The background model: origin, scale 5.
    public var backgroundObject: Int { Obj.background }
    public var backgroundTransform: Matrix4x4 { Matrix4x4.scale(5, 5, 5) }
}
