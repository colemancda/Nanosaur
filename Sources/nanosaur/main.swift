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

// Enemy item type -> (skeleton file name, walk animation #, scale, y lift).
private func enemyCreature(type: UInt16) -> (name: String, anim: Int, scale: Float, lift: Float)? {
    switch type {
    case 2: return ("Tricer", 0, 2.2, 0)   // Triceratops (walk)
    case 3: return ("Rex", 1, 1.2, 0)      // T-Rex (walk)
    case 7: return ("Ptera", 0, 1.0, 500)  // Pteranodon (fly, lifted off the ground)
    case 8: return ("Stego", 2, 1.4, 0)    // Stegosaurus (walk)
    case 16: return ("Diloph", 2, 0.8, 0)  // Dilophosaurus / spitter (walk)
    default: return nil
    }
}

/// Populates the world with animated enemies nearest the camera anchor (capped
/// for performance), each a live skeleton instance placed on the terrain.
private func loadEnemies(_ window: GameWindow, map: TerrainMap, geo: TerrainGeometry,
                         anchorX: Float, anchorZ: Float, cap: Int = 45) {
    let map2Unit: Float = 140.0 / 32.0
    // Collect enemy items sorted by distance to the anchor.
    var candidates: [(item: TerrainItem, x: Float, z: Float, dist: Float)] = []
    for item in map.items where enemyCreature(type: item.type) != nil {
        let x = Float(item.x) * map2Unit, z = Float(item.y) * map2Unit
        let dx = x - anchorX, dz = z - anchorZ
        candidates.append((item, x, z, dx * dx + dz * dz))
    }
    candidates.sort { $0.dist < $1.dist }

    var cache: [String: SkeletonModel] = [:]
    let fm = FileManager.default
    for c in candidates.prefix(cap) {
        guard let creature = enemyCreature(type: c.item.type) else { continue }
        let model: SkeletonModel
        if let cached = cache[creature.name] {
            model = cached
        } else {
            guard let md = fm.contents(atPath: "Data/Skeletons/\(creature.name).3dmf"),
                  let meshFile = try? MetaFile3D(parsing3DMF: md),
                  let sd = fm.contents(atPath: "Data/Skeletons/\(creature.name).skeleton.rsrc"),
                  let skelFile = try? SkeletonFile(parsingResourceFork: sd)
            else { continue }
            model = SkeletonModel(meshFile: meshFile, skeletonFile: skelFile)
            cache[creature.name] = model
        }

        // Each enemy needs its own render meshes (its own deformed geometry).
        guard let md = fm.contents(atPath: "Data/Skeletons/\(creature.name).3dmf"),
              let meshFile = try? MetaFile3D(parsing3DMF: md) else { continue }
        let instance = SkeletonInstance(model: model, animNum: creature.anim)
        let render = RenderableModel(meshFile)
        let y = geo.heightAtWorld(c.x, c.z) + creature.lift
        let yaw = Float(c.item.parm[0]) * (.pi / 4) // aim 0..7
        let base = Matrix4x4.scale(creature.scale, creature.scale, creature.scale)
            .multiplied(by: Matrix4x4.rotationY(yaw))
            .multiplied(by: Matrix4x4.translate(c.x, y, c.z))
        window.enemies.append(AnimatedEnemy(instance: instance, render: render, baseTransform: base))
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

    window.terrain = (mesh, atlas, geo.startX, geo.startZ, geo.startHeight)
    window.terrainHeight = { geo.heightAtWorld($0, $1) }
    window.hud = HUD(dataDir: "Data")

    // Roaming animated enemies near the player start.
    loadEnemies(window, map: map, geo: geo, anchorX: geo.startX, anchorZ: geo.startZ)

    // The driveable player (the Deinonychus), unless NANOSAUR_ORBIT is set.
    if ProcessInfo.processInfo.environment["NANOSAUR_ORBIT"] == nil,
       let pd = fm.contents(atPath: "Data/Skeletons/Deinon.3dmf"),
       let pMeshFile = try? MetaFile3D(parsing3DMF: pd),
       let ps = fm.contents(atPath: "Data/Skeletons/Deinon.skeleton.rsrc"),
       let pSkelFile = try? SkeletonFile(parsingResourceFork: ps) {
        let pModel = SkeletonModel(meshFile: pMeshFile, skeletonFile: pSkelFile)
        let start = Point3D(x: geo.startX, y: geo.startHeight, z: geo.startZ)
        window.player = PlayerController(model: pModel, render: RenderableModel(pMeshFile), start: start)
    }
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

    // NANOSAUR_SKELETON / NANOSAUR_MODEL are standalone viewer modes (used for
    // asset inspection screenshots); they bypass the screen flow entirely.
    if env["NANOSAUR_SKELETON"] != nil, let skeleton = loadDemoSkeleton() {
        window.skeleton = skeleton
    } else if env["NANOSAUR_MODEL"] != nil {
        window.model = loadDemoModel()
    } else {
        // The real app flow: title -> menu -> game, built together so the
        // player can navigate between them, matching Boot.cpp's sequence of
        // DoTitleScreen() -> DoMainMenu() -> the level game loop.
        window.title = TitleScene(dataDir: "Data")
        window.menu = MenuScene(dataDir: "Data")
        _ = loadDemoTerrain(window)

        // Direct-jump overrides, for quickly screenshotting/iterating on one
        // screen without having to drive the keyboard flow to reach it.
        if env["NANOSAUR_MENU"] != nil {
            window.screen = .menu
        } else if env["NANOSAUR_ORBIT"] != nil || env["NANOSAUR_GAME"] != nil {
            window.screen = .game
        } else if env["NANOSAUR_TITLE"] != nil {
            window.screen = .title
        } else if window.title == nil {
            // Title assets missing (shouldn't happen with a proper Data/
            // folder) - fall straight into the game so there's still
            // something playable.
            window.screen = .game
        }
        // Otherwise the default screen (.title) starts the normal flow: any
        // key -> menu; Left/Right to select, Space/Return to confirm; Escape
        // in-game returns to the menu.
    }
    window.run(maxFrames: maxFrames, screenshotPath: screenshotPath)
} catch {
    FileHandle.standardError.write(Data("Nanosaur failed to start: \(error)\n".utf8))
    exit(1)
}
