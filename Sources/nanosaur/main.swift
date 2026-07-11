// main.swift - Executable entry point. Opens the game window and runs the main
// loop. (The original entry point is main() in src/Boot.cpp.)
import Foundation
import NanosaurApp
import NanosaurSkeleton
import NanosaurTerrain
import QD3DFile
import QD3DMath
import SkeletonFile
import TerrainFile

/// Loads a .3dmf model's meshes as renderables, if the file exists. While the
/// full engine is being ported the executable acts as a model viewer: it shows
/// the first model it finds so there's something on screen.
private func loadDemoModel() -> RenderableModel? {
    // Allow overriding which model to view: NANOSAUR_MODEL=path
    let env = ProcessInfo.processInfo.environment
    var candidates = ["Data/Skeletons/Rex.3dmf", "Data/Models/Title.3dmf", "Data/Models/Global_Models.3dmf"]
    if let override = env["NANOSAUR_MODEL"] { candidates.insert(override, at: 0) }

    let fm = FileManager.default
    for path in candidates where fm.fileExists(atPath: path) {
        guard let data = fm.contents(atPath: path),
              let file = try? MetaFile3D(parsing3DMF: data),
              !file.meshes.isEmpty
        else { continue }
        return RenderableModel(file)
    }
    return nil
}

// Optional headless/testing knobs: run a fixed number of frames and/or capture
// a screenshot (used to verify the build renders without a display).
let env = ProcessInfo.processInfo.environment
let maxFrames = env["NANOSAUR_MAX_FRAMES"].flatMap { Int($0) }
let screenshotPath = env["NANOSAUR_SCREENSHOT"]

/// Loads an animated skeleton (creature + its .skeleton file) as the scene.
/// NANOSAUR_SKELETON=Name picks the creature; NANOSAUR_ANIM=N picks the anim.
private func loadDemoSkeleton() -> (instance: SkeletonInstance, render: RenderableModel)? {
    let env = ProcessInfo.processInfo.environment
    let name = env["NANOSAUR_SKELETON"] ?? "Rex"
    let animNum = env["NANOSAUR_ANIM"].flatMap { Int($0) } ?? 1

    let fm = FileManager.default
    let modelPath = "Data/Skeletons/\(name).3dmf"
    let skelPath = "Data/Skeletons/\(name).skeleton.rsrc"
    guard let md = fm.contents(atPath: modelPath),
          let meshFile = try? MetaFile3D(parsing3DMF: md),
          let sd = fm.contents(atPath: skelPath),
          let skelFile = try? SkeletonFile(parsingResourceFork: sd)
    else { return nil }

    let model = SkeletonModel(meshFile: meshFile, skeletonFile: skelFile)
    let instance = SkeletonInstance(model: model, animNum: animNum)
    return (instance, RenderableModel(meshFile))
}

// Maps a terrain item type (+ its parameters) to a Level1_Models object index,
// scale, and ground offset. Covers the static scenery (Terrain2.c's add-routine
// table); enemies/pickups are placed elsewhere. Object indices are
// LEVEL0_MObjType_* ordinals (mobjtypes.h).
private func sceneryModel(type: UInt16, parm: [UInt8]) -> (object: Int, scale: Float, yOffset: Float)? {
    // Per-tree scales (Items.c AddTree): fern, stickpalm, bamboo, cypress, palm, pine.
    let treeScales: [Float] = [1.0, 1.1, 1.0, 4.0, 1.2, 1.3]
    switch type {
    case 5: return (3 + Int(parm[0] % 5), 0.6, -5)   // Egg1..5
    case 6: return (22, 0.5, 0)                        // GasVent
    case 10: return (16 + Int(parm[0] % 6), treeScales[Int(parm[0] % 6)], 0) // Tree1..6
    case 11: return (8, 1.5, -10)                      // Boulder
    case 12: return (10, 1.5, 0)                       // Mushroom
    case 13: return (11, 4.2, -30)                     // Bush
    case 15: return (12 + Int(parm[0] % 3), 2.0, 0)    // Crystal1..3
    case 19: return (24, 0.5, 0)                        // Spore Pod
    default: return nil
    }
}

/// Loads Level 1's terrain (heightmap mesh + tileset atlas) plus its scenery.
private func loadDemoTerrain(_ window: GameWindow) -> Bool {
    let fm = FileManager.default
    guard let td = fm.contents(atPath: "Data/Terrain/Level1.ter"),
          let map = try? TerrainMap(parsing: td),
          let sd = fm.contents(atPath: "Data/Terrain/Level1.trt"),
          let tileset = try? TerrainTileset(parsing: sd)
    else { return false }

    let geo = TerrainGeometry(map: map, tileset: tileset)
    guard let atlas = Texture2D(rgba: geo.atlasRGBA, width: geo.atlasWidth, height: geo.atlasHeight) else { return false }
    let mesh = RenderableMesh(points: geo.points, normals: geo.normals, uvs: geo.uvs,
                              indices: geo.indices, textureName: atlas.name)

    // Populate the world with scenery from the terrain item list.
    let map2Unit: Float = 140.0 / 32.0 // MAP2UNIT_VALUE

    // Anchor the fly-over camera on the densest scenery cluster (so the
    // populated world is actually in view), bucketing items into 3000-unit cells.
    var cellCounts: [Int64: Int] = [:]
    let sceneryTypes: Set<UInt16> = [5, 6, 10, 11, 12, 13, 15, 19]
    for item in map.items where sceneryTypes.contains(item.type) {
        let cx = Int64(Float(item.x) * map2Unit / 3000)
        let cz = Int64(Float(item.y) * map2Unit / 3000)
        cellCounts[cx << 32 | (cz & 0xFFFF_FFFF), default: 0] += 1
    }
    var anchorX = geo.startX, anchorZ = geo.startZ
    if let best = cellCounts.max(by: { $0.value < $1.value })?.key {
        anchorX = (Float(best >> 32) + 0.5) * 3000
        anchorZ = (Float(Int32(truncatingIfNeeded: best)) + 0.5) * 3000
    }
    window.terrain = (mesh, atlas, anchorX, anchorZ, geo.heightAtWorld(anchorX, anchorZ))
    if let modelData = fm.contents(atPath: "Data/Models/Level1_Models.3dmf"),
       let modelFile = try? MetaFile3D(parsing3DMF: modelData) {
        let model = RenderableModel(modelFile)
        var placements: [(object: Int, transform: Matrix4x4)] = []
        for item in map.items {
            guard let s = sceneryModel(type: item.type, parm: item.parm), s.object < model.objects.count else { continue }
            let wx = Float(item.x) * map2Unit
            let wz = Float(item.y) * map2Unit
            let wy = geo.heightAtWorld(wx, wz) + s.yOffset
            // Deterministic yaw for variety.
            let yaw = Float((Int(item.x) * 3 + Int(item.y) * 7) % 628) / 100
            let t = Matrix4x4.scale(s.scale, s.scale, s.scale)
                .multiplied(by: Matrix4x4.rotationY(yaw))
                .multiplied(by: Matrix4x4.translate(wx, wy, wz))
            placements.append((s.object, t))
        }
        window.scenery = (model, placements)
    }
    return true
}

do {
    let window = try GameWindow()
    let env = ProcessInfo.processInfo.environment
    // Default to the terrain fly-over; NANOSAUR_SKELETON shows a creature,
    // NANOSAUR_MODEL a static model.
    if env["NANOSAUR_SKELETON"] != nil, let skeleton = loadDemoSkeleton() {
        window.skeleton = skeleton
    } else if env["NANOSAUR_MODEL"] != nil {
        window.model = loadDemoModel()
    } else if !loadDemoTerrain(window) {
        if let skeleton = loadDemoSkeleton() { window.skeleton = skeleton }
        else { window.model = loadDemoModel() }
    }
    window.run(maxFrames: maxFrames, screenshotPath: screenshotPath)
} catch {
    FileHandle.standardError.write(Data("Nanosaur failed to start: \(error)\n".utf8))
    exit(1)
}
