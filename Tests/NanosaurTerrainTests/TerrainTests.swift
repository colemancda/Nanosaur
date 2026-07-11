import Foundation
import Testing

@testable import NanosaurTerrain
import TerrainFile

private func loadLevel1() throws -> (TerrainMap, TerrainTileset) {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let dir = root.appendingPathComponent("Data/Terrain")
    let map = try TerrainMap(parsing: try Data(contentsOf: dir.appendingPathComponent("Level1.ter")))
    let tileset = try TerrainTileset(parsing: try Data(contentsOf: dir.appendingPathComponent("Level1.trt")))
    return (map, tileset)
}

@Test func terrainBuildsExpectedGeometry() throws {
    let (map, tileset) = try loadLevel1()
    let geo = TerrainGeometry(map: map, tileset: tileset)

    let tiles = map.tileWidth * map.tileDepth
    #expect(geo.points.count == tiles * 4 * 3)  // 4 verts/tile, 3 floats/vert
    #expect(geo.uvs.count == tiles * 4 * 2)
    #expect(geo.indices.count == tiles * 6)      // 2 triangles/tile

    // All heights finite, non-negative, and within the extruded range (0..255*4).
    var maxY: Float = 0
    var i = 1
    while i < geo.points.count {
        let y = geo.points[i]
        #expect(y.isFinite && y >= 0 && y <= 255 * 4)
        maxY = max(maxY, y)
        i += 3
    }
    #expect(maxY > 0) // the level isn't flat

    // Every index references a real vertex.
    let vertexCount = tiles * 4
    for idx in geo.indices { #expect(Int(idx) < vertexCount) }
}

@Test func atlasCoversTilesetAndUVsInRange() throws {
    let (map, tileset) = try loadLevel1()
    let geo = TerrainGeometry(map: map, tileset: tileset)

    // Atlas is big enough to hold every tile as a 32x32 cell.
    let cells = (geo.atlasWidth / 32) * (geo.atlasHeight / 32)
    #expect(cells >= tileset.tileCount)
    #expect(geo.atlasRGBA.count == geo.atlasWidth * geo.atlasHeight * 4)

    // UVs stay within [0,1].
    for uv in geo.uvs { #expect(uv >= 0 && uv <= 1) }
}

@Test func startCoordIsWithinTheMap() throws {
    let (map, tileset) = try loadLevel1()
    let geo = TerrainGeometry(map: map, tileset: tileset)
    #expect(geo.startX >= 0 && geo.startX <= Float(map.tileWidth) * 140)
    #expect(geo.startZ >= 0 && geo.startZ <= Float(map.tileDepth) * 140)
}
