import Foundation
import Testing

@testable import TerrainFile

private func terrainDir() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // TerrainFileTests.swift -> TerrainFileTests/
        .deletingLastPathComponent() // -> Tests/
        .deletingLastPathComponent() // -> repo root
        .appendingPathComponent("Data/Terrain")
}

@Test func tilesetParses() throws {
    let url = terrainDir().appendingPathComponent("Level1.trt")
    let tileset = try TerrainTileset(parsing: try Data(contentsOf: url))
    #expect(tileset.tileCount == 258)
    // One 32x32 16-bit tile per tile.
    #expect(tileset.texels.count == 258 * terrainTileSize * terrainTileSize)
}

@Test func mapParses() throws {
    let url = terrainDir().appendingPathComponent("Level1.ter")
    let map = try TerrainMap(parsing: try Data(contentsOf: url))

    #expect(map.tileWidth == 270)
    #expect(map.tileDepth == 355)

    let expectedLayerCount = 270 * 355
    #expect(map.textureLayer.count == expectedLayerCount)
    #expect(map.heightMapLayer?.count == expectedLayerCount)
    #expect(map.pathLayer?.count == expectedLayerCount)

    // 258 texture tiles -> 258 tile-attribute records.
    #expect(map.tileAttributes.count == 258)

    // Heightmap tiles come in whole 32x32-byte tiles.
    #expect(map.heightMapTiles.count % (terrainTileSize * terrainTileSize) == 0)
    #expect(map.heightMapTiles.count / (terrainTileSize * terrainTileSize) == 248)

    #expect(map.items.count == 1641)
}

@Test func textureLayerIndicesAddressRealTiles() throws {
    // Every tile index in the texture layer (masked to its low bits, which
    // hold the tile number) must reference a real tile in the tileset. This
    // cross-checks the .ter and .trt big-endian decodes against each other.
    let map = try TerrainMap(parsing: try Data(contentsOf: terrainDir().appendingPathComponent("Level1.ter")))
    let tileset = try TerrainTileset(parsing: try Data(contentsOf: terrainDir().appendingPathComponent("Level1.trt")))

    // Tile number is stored in the low 12 bits (TILENUM_MASK); the upper bits
    // are flip/rotate flags.
    let tileNumMask: UInt16 = 0x0FFF
    for value in map.textureLayer {
        let tileNum = Int(value & tileNumMask)
        #expect(tileNum < tileset.tileCount)
    }
}
