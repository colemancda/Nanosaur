// TitleScene.swift - The title screen, ported from src/Screens/Title.c: the
// "Nanosaur" GameName logo and a tiled cyclorama background from Title.3dmf,
// with an animated Rex, viewed from the fixed title camera. The fade and the
// click-to-continue transition are handled by the screen flow once input is
// wired.
import Foundation
import NanosaurSkeleton
import QD3DFile
import QD3DMath
import SkeletonFile

public final class TitleScene {
    // Title.3dmf object indices (mobjtypes.h): GameName=0, Pangea=1, Background=2.
    public static let gameNameIndex = 0
    public static let backgroundIndex = 2

    let model: RenderableModel
    let gameNameTransform: Matrix4x4
    let backgroundTransforms: [Matrix4x4]

    let rexInstance: SkeletonInstance
    let rexRender: RenderableModel
    let rexTransform: Matrix4x4

    // Title camera (Title.c): from (110,90,190) looking at the origin, fov 1 rad.
    public let cameraFrom = Point3D(x: 110, y: 90, z: 190)
    public let cameraTo = Point3D(x: 0, y: 0, z: 0)
    public let fovDegrees: Float = 57 // 1.0 radian

    public init?(dataDir: String) {
        let fm = FileManager.default
        guard let md = fm.contents(atPath: "\(dataDir)/Models/Title.3dmf"),
              let titleFile = try? MetaFile3D(parsing3DMF: md),
              let rexMesh = fm.contents(atPath: "\(dataDir)/Skeletons/Rex.3dmf"),
              let rexMeshFile = try? MetaFile3D(parsing3DMF: rexMesh),
              let rexSkelData = fm.contents(atPath: "\(dataDir)/Skeletons/Rex.skeleton.rsrc"),
              let rexSkelFile = try? SkeletonFile(parsingResourceFork: rexSkelData)
        else { return nil }

        model = RenderableModel(titleFile)

        // GameName logo: coord (60,15,100), yaw 0.9, scale 0.4.
        gameNameTransform = Matrix4x4.scale(0.4, 0.4, 0.4)
            .multiplied(by: Matrix4x4.rotationY(0.9))
            .multiplied(by: Matrix4x4.translate(60, 15, 100))

        // Tiled background cyclorama.
        let bgScale: Float = 2.6, bgLeftmostX: Float = -600, bgLength: Float = 300
        var transforms: [Matrix4x4] = []
        var x = bgLeftmostX * bgScale
        for _ in 0..<5 {
            transforms.append(Matrix4x4.scale(bgScale, bgScale, bgScale)
                .multiplied(by: Matrix4x4.translate(x, 0, -40)))
            x += bgLength * bgScale
        }
        backgroundTransforms = transforms

        // Animated Rex: coord (10,0,70), yaw -PI/2, scale 0.5.
        let rexModel = SkeletonModel(meshFile: rexMeshFile, skeletonFile: rexSkelFile)
        rexInstance = SkeletonInstance(model: rexModel, animNum: 1) // walk
        rexRender = RenderableModel(rexMeshFile)
        rexTransform = Matrix4x4.scale(0.5, 0.5, 0.5)
            .multiplied(by: Matrix4x4.rotationY(-.pi / 2))
            .multiplied(by: Matrix4x4.translate(10, 0, 70))
    }
}
