import Foundation
import Testing

@testable import SkeletonFile

private func skeletonURLs() -> [URL] {
    let dir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // SkeletonFileTests.swift -> SkeletonFileTests/
        .deletingLastPathComponent() // -> Tests/
        .deletingLastPathComponent() // -> repo root
        .appendingPathComponent("Data/Skeletons")
    let fm = FileManager.default
    guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
    return e.compactMap { $0 as? URL }
        .filter { $0.lastPathComponent.hasSuffix(".skeleton.rsrc") }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

private func load(_ name: String) throws -> SkeletonFile {
    let url = skeletonURLs().first { $0.lastPathComponent == name }!
    return try SkeletonFile(parsingResourceFork: try Data(contentsOf: url))
}

@Test func allSkeletonsDecode() throws {
    let urls = skeletonURLs()
    #expect(urls.count == 6)
    for url in urls {
        let skeleton = try SkeletonFile(parsingResourceFork: try Data(contentsOf: url))
        #expect(skeleton.numJoints > 0)
        #expect(skeleton.numAnims > 0)
        #expect(!skeleton.relativePointOffsets.isEmpty)
        // Every anim tracks exactly one keyframe list per joint.
        for anim in skeleton.anims {
            #expect(anim.jointKeyframes.count == skeleton.numJoints)
        }
    }
}

@Test func deinonHasExpectedStructure() throws {
    let deinon = try load("Deinon.skeleton.rsrc")
    #expect(deinon.version == 272)          // 0x0110
    #expect(deinon.numJoints == 20)
    #expect(deinon.numAnims == 15)
    #expect(deinon.num3DMFLimbs == 0)
    #expect(deinon.bones.count == 20)
    #expect(deinon.anims.count == 15)
    #expect(deinon.relativePointOffsets.count == 405)

    // Root bone parents to -1.
    #expect(deinon.bones[0].parentBone == -1)
}

@Test func bonePointIndicesAreInRange() throws {
    // Every point/normal index a bone owns must fall within the decomposed
    // reference-point list. This independently validates the big-endian
    // decode of the 'BonP' index arrays against the 'RelP' point count.
    for url in skeletonURLs() {
        let skeleton = try SkeletonFile(parsingResourceFork: try Data(contentsOf: url))
        let pointCount = skeleton.relativePointOffsets.count
        for bone in skeleton.bones {
            for index in bone.pointIndices {
                #expect(Int(index) < pointCount,
                        "\(url.lastPathComponent): point index \(index) out of range (\(pointCount))")
            }
        }
    }
}

@Test func keyframeTracksAreNonEmpty() throws {
    // Animations should have keyframes; the first keyframe of a track starts
    // at tick 0 (validates the big-endian Int32 decode).
    let deinon = try load("Deinon.skeleton.rsrc")
    let firstTrack = deinon.anims[0].jointKeyframes[0]
    #expect(!firstTrack.isEmpty)
    #expect(firstTrack[0].tick == 0)
}
