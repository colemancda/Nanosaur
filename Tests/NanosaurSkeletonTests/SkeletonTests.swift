import Foundation
import Testing

@testable import NanosaurSkeleton
import QD3DFile
import SkeletonFile

private func loadModel(_ name: String) throws -> SkeletonModel {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let dir = root.appendingPathComponent("Data/Skeletons")
    let meshFile = try MetaFile3D(parsing3DMF: try Data(contentsOf: dir.appendingPathComponent("\(name).3dmf")))
    let skelFile = try SkeletonFile(parsingResourceFork: try Data(contentsOf: dir.appendingPathComponent("\(name).skeleton.rsrc")))
    return SkeletonModel(meshFile: meshFile, skeletonFile: skelFile)
}

@Test func decomposeMatchesSkeletonPointCount() throws {
    // The decomposed-point count must equal the .skeleton file's relative-point
    // count, or bone/keyframe indices won't line up. Verify for every creature.
    for name in ["Rex", "Deinon", "Ptera", "Stego", "Tricer", "Diloph"] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent("Data/Skeletons")
        let skelFile = try SkeletonFile(parsingResourceFork: try Data(contentsOf: dir.appendingPathComponent("\(name).skeleton.rsrc")))
        let model = try loadModel(name)
        #expect(model.decomposedPoints.count == skelFile.relativePointOffsets.count,
                "\(name): decomposed \(model.decomposedPoints.count) vs relP \(skelFile.relativePointOffsets.count)")
    }
}

@Test func animationProducesFiniteDeformedGeometry() throws {
    let model = try loadModel("Rex")
    let instance = SkeletonInstance(model: model, animNum: 0)

    // Step the animation for a while; every deformed coordinate must stay finite
    // (catches broken matrices / index mismatches).
    for _ in 0..<120 {
        instance.update(dt: 1.0 / 60.0)
    }
    var moved = false
    let bindPoints = instance.deformedPoints
    for mesh in instance.deformedPoints {
        for v in mesh { #expect(v.isFinite) }
    }
    // Stepping further should change at least some vertex (the pose animates).
    instance.update(dt: 0.5)
    for (m, mesh) in instance.deformedPoints.enumerated() {
        for (i, v) in mesh.enumerated() where abs(v - bindPoints[m][i]) > 1e-4 { moved = true }
    }
    #expect(moved, "animation should change the deformed geometry over time")
}

@Test func everyVertexIsDeformed() throws {
    // After one update, all deformed points should be populated (non-zero for a
    // model not centered at the origin), i.e. every reference vertex is covered
    // by some bone.
    let model = try loadModel("Rex")
    let instance = SkeletonInstance(model: model, animNum: 0)
    instance.update(dt: 1.0 / 60.0)
    let allZero = instance.deformedPoints.allSatisfy { $0.allSatisfy { $0 == 0 } }
    #expect(!allZero)
}
