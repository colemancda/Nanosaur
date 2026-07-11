// Terrain.swift - Builds a renderable landscape from a parsed TerrainMap +
// TerrainTileset, ported from the geometry logic in src/Terrain/Terrain.c.
//
// The map is a width×depth grid of 140-unit tiles. Each grid vertex's height is
// the corner pixel of the heightmap tile assigned to that map cell, times
// HEIGHT_EXTRUDE_FACTOR (GetTerrainHeightAtRowCol). Each tile is textured from
// the tileset. Rather than stream 5×5 "supertiles" like the original, this
// builds the whole terrain once (fine for a static fly-over): every tile gets
// its own 4 vertices so it can carry its own texture, all sampled from a single
// atlas packed from the tileset so the terrain draws in one call.
import TerrainFile
import QD3DMath

private let polygonSize: Float = 140   // TERRAIN_POLYGON_SIZE
private let hmTileSize = 32             // TERRAIN_HMTILE_SIZE / OREOMAP_TILE_SIZE
private let heightExtrude: Float = 4    // HEIGHT_EXTRUDE_FACTOR
private let map2Unit: Float = polygonSize / Float(hmTileSize) // MAP2UNIT_VALUE
private let tileNumMask: UInt16 = 0x0FFF
private let flipXMask: UInt16 = 0x8000
private let flipYMask: UInt16 = 0x4000

public final class TerrainGeometry {
    public let points: [Float]  // 3 per vertex
    public let normals: [Float] // 3 per vertex
    public let uvs: [Float]     // 2 per vertex
    public let indices: [UInt32]

    /// Texture atlas packed from every tileset tile (RGBA, row-major).
    public let atlasRGBA: [UInt8]
    public let atlasWidth: Int
    public let atlasHeight: Int

    /// Player start (world coords) + terrain height there, for camera placement.
    public let startX: Float
    public let startZ: Float
    public let startHeight: Float

    // Height grid (retained so scenery can be placed on the surface).
    private let heightGrid: [Float]
    private let gridWidth: Int
    private let gridDepth: Int

    /// Terrain height at a world (x, z), by nearest grid corner (the "quick"
    /// lookup the game uses for item placement).
    public func heightAtWorld(_ x: Float, _ z: Float) -> Float {
        let col = Int((x / polygonSize).rounded(.down))
        let row = Int((z / polygonSize).rounded(.down))
        guard row >= 0, row < gridDepth, col >= 0, col < gridWidth else { return 0 }
        return heightGrid[row * gridWidth + col]
    }

    public init(map: TerrainMap, tileset: TerrainTileset) {
        let width = map.tileWidth
        let depth = map.tileDepth
        let heightLayer = map.heightMapLayer ?? []
        let hmTiles = map.heightMapTiles
        let numHMTiles = hmTiles.count / (hmTileSize * hmTileSize)

        // --- height at a grid vertex (GetTerrainHeightAtRowCol) ---
        func heightAt(_ row: Int, _ col: Int) -> Float {
            guard row >= 0, row < depth, col >= 0, col < width, !heightLayer.isEmpty else { return 0 }
            let tile = heightLayer[row * width + col]
            let tileNum = Int(tile & tileNumMask)
            guard tileNum < numHMTiles else { return 0 }
            let offx = (tile & flipXMask) != 0 ? hmTileSize - 1 : 0
            let offy = (tile & flipYMask) != 0 ? hmTileSize - 1 : 0
            let pixel = hmTiles[tileNum * hmTileSize * hmTileSize + offy * hmTileSize + offx]
            return Float(pixel) * heightExtrude
        }

        // Precompute the (depth+1)×(width+1) height + normal grids.
        let gw = width + 1, gd = depth + 1
        var hgrid = [Float](repeating: 0, count: gw * gd)
        for r in 0..<gd { for c in 0..<gw { hgrid[r * gw + c] = heightAt(r, c) } }

        func h(_ r: Int, _ c: Int) -> Float {
            (r >= 0 && r < gd && c >= 0 && c < gw) ? hgrid[r * gw + c] : heightAt(r, c)
        }
        var ngrid = [Float](repeating: 0, count: gw * gd * 3)
        for r in 0..<gd {
            for c in 0..<gw {
                // Slope from neighbor heights (matches Terrain.c's normal calc).
                let nx = (h(r, c - 1) - h(r, c + 1)) * 0.01
                let nz = (h(r - 1, c) - h(r + 1, c)) * 0.01
                let n = Vector3D(x: nx, y: 1, z: nz).normalized()
                ngrid[(r * gw + c) * 3 + 0] = n.x
                ngrid[(r * gw + c) * 3 + 1] = n.y
                ngrid[(r * gw + c) * 3 + 2] = n.z
            }
        }

        // --- texture atlas from the tileset ---
        let tileCount = max(1, tileset.tileCount)
        let cols = Int(Double(tileCount).squareRoot().rounded(.up))
        let rows = (tileCount + cols - 1) / cols
        let aw = cols * hmTileSize, ah = rows * hmTileSize
        var atlas = [UInt8](repeating: 0, count: aw * ah * 4)
        for t in 0..<tileCount {
            let cellX = (t % cols) * hmTileSize
            let cellY = (t / cols) * hmTileSize
            for py in 0..<hmTileSize {
                for px in 0..<hmTileSize {
                    let texel = tileset.texels[t * hmTileSize * hmTileSize + py * hmTileSize + px]
                    // 16-bit 1-5-5-5 (same as the model textures).
                    let r = UInt8((Int((texel >> 10) & 0x1F) * 255) / 31)
                    let g = UInt8((Int((texel >> 5) & 0x1F) * 255) / 31)
                    let b = UInt8((Int(texel & 0x1F) * 255) / 31)
                    let ai = ((cellY + py) * aw + (cellX + px)) * 4
                    atlas[ai + 0] = r; atlas[ai + 1] = g; atlas[ai + 2] = b; atlas[ai + 3] = 255
                }
            }
        }
        atlasRGBA = atlas
        atlasWidth = aw
        atlasHeight = ah

        // --- geometry: 4 verts + 2 triangles per tile ---
        let tileTotal = width * depth
        var pts = [Float](repeating: 0, count: tileTotal * 4 * 3)
        var nrm = [Float](repeating: 0, count: tileTotal * 4 * 3)
        var uv = [Float](repeating: 0, count: tileTotal * 4 * 2)
        var idx = [UInt32](repeating: 0, count: tileTotal * 6)
        let halfTexelU = 0.5 / Float(aw), halfTexelV = 0.5 / Float(ah)

        var tile = 0
        for row in 0..<depth {
            for col in 0..<width {
                let texTile = Int(map.textureLayer[row * width + col] & tileNumMask)
                let tn = min(texTile, tileCount - 1)
                let cx = (tn % cols) * hmTileSize, cy = (tn / cols) * hmTileSize
                let u0 = Float(cx) / Float(aw) + halfTexelU
                let u1 = Float(cx + hmTileSize) / Float(aw) - halfTexelU
                let v0 = Float(cy) / Float(ah) + halfTexelV
                let v1 = Float(cy + hmTileSize) / Float(ah) - halfTexelV

                // Four corners: UL, UR, LR, LL (col=+x, row=+z).
                let corners = [(col, row, u0, v0), (col + 1, row, u1, v0),
                               (col + 1, row + 1, u1, v1), (col, row + 1, u0, v1)]
                let base = tile * 4
                for (k, corner) in corners.enumerated() {
                    let (cc, rr, cu, cv) = corner
                    let vi = base + k
                    pts[vi * 3 + 0] = Float(cc) * polygonSize
                    pts[vi * 3 + 1] = h(rr, cc)
                    pts[vi * 3 + 2] = Float(rr) * polygonSize
                    let gn = (rr * gw + cc) * 3
                    nrm[vi * 3 + 0] = ngrid[gn + 0]
                    nrm[vi * 3 + 1] = ngrid[gn + 1]
                    nrm[vi * 3 + 2] = ngrid[gn + 2]
                    uv[vi * 2 + 0] = cu
                    uv[vi * 2 + 1] = cv
                }
                let ii = tile * 6
                let b = UInt32(base)
                idx[ii + 0] = b; idx[ii + 1] = b + 1; idx[ii + 2] = b + 2
                idx[ii + 3] = b; idx[ii + 4] = b + 2; idx[ii + 5] = b + 3
                tile += 1
            }
        }
        points = pts; normals = nrm; uvs = uv; indices = idx

        // --- player start, for camera placement ---
        var sx: Float = Float(width) * polygonSize / 2
        var sz: Float = Float(depth) * polygonSize / 2
        if let start = map.items.first(where: { $0.type == 0 }) { // MAP_ITEM_MYSTARTCOORD
            sx = Float(start.x) * map2Unit
            sz = Float(start.y) * map2Unit
        }
        startX = sx
        startZ = sz
        startHeight = heightAt(Int(sz / polygonSize), Int(sx / polygonSize))

        heightGrid = hgrid
        gridWidth = gw
        gridDepth = gd
    }
}
