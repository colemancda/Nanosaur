// TerrainFile.swift - Parsers for Nanosaur's OreoTerrain data files:
//   .trt  the texture tileset (TerrainTileset)
//   .ter  the terrain map itself (TerrainMap)
// replacing LoadTerrainTileset()/LoadTerrain() in src/System/File.c with pure,
// tested, standalone parsers. All multi-byte values are big-endian.
//
// .trt tileset:
//   Int32 tileCount, then tileCount * 32*32 UInt16 texels (16-bit textures).
//
// .ter map header (40 bytes, ">7l 2h 2l"):
//   [0]  offset to texture layer      [4]  offset to heightmap layer
//   [8]  offset to path layer         [12] offset to item list
//   [16] (unused)                     [20] offset to heightmap tiles
//   [24] (unused)                     [28] width (tiles)  [30] depth (tiles)
//   [32] offset to tile attributes    [36] offset to (unused) tile-anim data
// Each of the texture/heightmap/path layers is width*depth UInt16 values, row
// major. Tile attributes are TileAttribType ">Hhbbh" records; their count is
// derived from the gap to the next chunk. Heightmap tiles are raw 32*32 byte
// tiles. The item list is an Int32 count followed by TerrainItemEntryType
// ">hhh4bHll" records (the two trailing longs are always zero in the file).
#if canImport(BinaryParsing)
import BinaryParsing
#endif

public enum TerrainParsingError: Error, Sendable, Equatable {
    case tilesetSizeMismatch
}

#if $Embedded
private func terrainThrow(_ error: TerrainParsingError) -> ParsingError {
    ParsingError(statusOnly: .invalidValue)
}
#else
private func terrainThrow(_ error: TerrainParsingError) -> TerrainParsingError {
    error
}
#endif

/// Pixel width/height of a single terrain tile (OREOMAP_TILE_SIZE /
/// TERRAIN_HMTILE_SIZE in the C engine).
public let terrainTileSize = 32

/// A parsed .trt texture tileset: `tileCount` tiles of 32x32 16-bit texels,
/// stored consecutively in `texels` (row-major within each tile).
public struct TerrainTileset: Sendable, Equatable {
    public var tileCount: Int
    public var texels: [UInt16]
}

extension TerrainTileset: ExpressibleByParsing {
    public init(parsing input: inout ParserSpan) throws(ThrownParsingError) {
        let fileSize = input.count
        let tileCount = try Int(Int32(parsingBigEndian: &input))
        let texelCount = tileCount * terrainTileSize * terrainTileSize
        guard texelCount * 2 == fileSize - 4 else {
            throw terrainThrow(.tilesetSizeMismatch)
        }
        var texels = [UInt16]()
        texels.reserveCapacity(texelCount)
        for _ in 0..<texelCount {
            texels.append(try UInt16(parsingBigEndian: &input))
        }
        self.tileCount = tileCount
        self.texels = texels
    }
}

/// One tile attribute record (collision/behavior bits + parameters).
public struct TileAttribute: Sendable, Equatable {
    public var bits: UInt16
    public var parm0: Int16
    public var parm1: UInt8
    public var parm2: UInt8
    public var undefined: Int16
}

/// One placed terrain item (enemy, tree, powerup, start coord, ...) from the
/// map's object list.
public struct TerrainItem: Sendable, Equatable {
    public var x: UInt16 // tile column
    public var y: UInt16 // tile row
    public var type: UInt16
    public var parm: [UInt8] // 4 parameter bytes
    public var flags: UInt16
}

/// A parsed .ter terrain map.
public struct TerrainMap: Sendable, Equatable {
    public var tileWidth: Int
    public var tileDepth: Int
    /// Row-major (`row * tileWidth + col`), `tileDepth * tileWidth` entries.
    public var textureLayer: [UInt16]
    public var heightMapLayer: [UInt16]?
    public var pathLayer: [UInt16]?
    public var tileAttributes: [TileAttribute]
    /// Raw 8-bit heightmap tile definitions (32x32 bytes each), concatenated.
    public var heightMapTiles: [UInt8]
    public var items: [TerrainItem]
}

extension TerrainMap: ExpressibleByParsing {
    public init(parsing input: inout ParserSpan) throws(ThrownParsingError) {
        let fileSize = input.count

        let texLayerOff = try Int(Int32(parsingBigEndian: &input))
        let heightLayerOff = try Int(Int32(parsingBigEndian: &input))
        let pathLayerOff = try Int(Int32(parsingBigEndian: &input))
        let itemListOff = try Int(Int32(parsingBigEndian: &input))
        _ = try Int32(parsingBigEndian: &input) // [16] unused
        let hmTilesOff = try Int(Int32(parsingBigEndian: &input))
        _ = try Int32(parsingBigEndian: &input) // [24] unused
        let width = try Int(Int16(parsingBigEndian: &input))
        let depth = try Int(Int16(parsingBigEndian: &input))
        let texAttrOff = try Int(Int32(parsingBigEndian: &input))
        let tileAnimOff = try Int(Int32(parsingBigEndian: &input))

        let layerCount = width * depth

        // Texture layer (always present).
        var textureLayer = [UInt16]()
        textureLayer.reserveCapacity(layerCount)
        var texSpan = try input.seeking(toAbsoluteOffset: texLayerOff)
        for _ in 0..<layerCount {
            textureLayer.append(try UInt16(parsingBigEndian: &texSpan))
        }

        // Heightmap layer (optional).
        var heightMapLayer: [UInt16]?
        if heightLayerOff > 0 {
            var layer = [UInt16]()
            layer.reserveCapacity(layerCount)
            var span = try input.seeking(toAbsoluteOffset: heightLayerOff)
            for _ in 0..<layerCount {
                layer.append(try UInt16(parsingBigEndian: &span))
            }
            heightMapLayer = layer
        }

        // Path layer (optional).
        var pathLayer: [UInt16]?
        if pathLayerOff > 0 {
            var layer = [UInt16]()
            layer.reserveCapacity(layerCount)
            var span = try input.seeking(toAbsoluteOffset: pathLayerOff)
            for _ in 0..<layerCount {
                layer.append(try UInt16(parsingBigEndian: &span))
            }
            pathLayer = layer
        }

        // Tile attributes: count derived from the gap to the next chunk
        // (mirrors the "source port cheat" in File.c's LoadTerrain).
        var tileAttributes = [TileAttribute]()
        if texAttrOff > 0 && tileAnimOff > texAttrOff {
            let count = (tileAnimOff - texAttrOff) / 8 // sizeof(TileAttribType)
            tileAttributes.reserveCapacity(count)
            var span = try input.seeking(toAbsoluteOffset: texAttrOff)
            for _ in 0..<count {
                let bits = try UInt16(parsingBigEndian: &span)
                let parm0 = try Int16(parsingBigEndian: &span)
                let parm1 = try UInt8(parsing: &span)
                let parm2 = try UInt8(parsing: &span)
                let undefined = try Int16(parsingBigEndian: &span)
                tileAttributes.append(TileAttribute(
                    bits: bits, parm0: parm0, parm1: parm1, parm2: parm2, undefined: undefined))
            }
        }

        // Heightmap tiles: raw bytes from their offset to the next chunk.
        var heightMapTiles = [UInt8]()
        if hmTilesOff > 0 {
            let laterOffsets = [
                texLayerOff, heightLayerOff, pathLayerOff, itemListOff,
                texAttrOff, tileAnimOff,
            ].filter { $0 > hmTilesOff }
            let end = laterOffsets.min() ?? fileSize
            var span = try input.seeking(toAbsoluteOffset: hmTilesOff)
            heightMapTiles = try [UInt8](parsing: &span, byteCount: end - hmTilesOff)
        }

        // Item list.
        var items = [TerrainItem]()
        if itemListOff > 0 {
            var span = try input.seeking(toAbsoluteOffset: itemListOff)
            let numItems = try Int(Int32(parsingBigEndian: &span))
            items.reserveCapacity(numItems)
            for _ in 0..<numItems {
                let x = try UInt16(parsingBigEndian: &span)
                let y = try UInt16(parsingBigEndian: &span)
                let type = try UInt16(parsingBigEndian: &span)
                let parm = try [UInt8](parsing: &span, byteCount: 4)
                let flags = try UInt16(parsingBigEndian: &span)
                _ = try Int32(parsingBigEndian: &span) // trailing "pointer" (zero)
                _ = try Int32(parsingBigEndian: &span) // trailing "pointer" (zero)
                items.append(TerrainItem(x: x, y: y, type: type, parm: parm, flags: flags))
            }
        }

        self.tileWidth = width
        self.tileDepth = depth
        self.textureLayer = textureLayer
        self.heightMapLayer = heightMapLayer
        self.pathLayer = pathLayer
        self.tileAttributes = tileAttributes
        self.heightMapTiles = heightMapTiles
        self.items = items
    }
}
