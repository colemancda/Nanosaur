// QD3DFile.swift - Parser for the QuickDraw 3D Metafile (.3dmf) model files
// under Data/Models and Data/Skeletons, replacing Pomme's
// Q3MetaFile_Load3DMF (Pomme/src/QD3D/3DMFParser.cpp) with a pure, standalone
// Swift port.
//
// A 3DMF file is a chunk stream: an 8-byte '3DMF' header, an optional
// table-of-contents (for 'rfrn' back-references), then a tree of 4-byte-tagged
// chunks. Each chunk is: fourcc type (UInt32), size (UInt32), payload. All
// multi-byte values are big-endian. Because chunks reference each other by
// absolute file offset (TOC + 'rfrn') and nest recursively, this uses a small
// random-access byte cursor rather than swift-binary-parsing's forward-only,
// non-escapable ParserSpan.
//
// Supported chunks (matching the C++ parser): 'cntr'/'bgng'/'endg' grouping,
// 'tmsh' TriMesh geometry, 'atar' vertex/face attribute arrays (UVs, normals,
// colors), 'txsu'/'txmm'/'txpm'/'shdr' texture shaders, 'kdif'/'kxpr' diffuse
// and transparency colors, 'rfrn'/'toc ' references.

public enum QD3DParsingError: Error, Sendable, Equatable {
    case notA3DMF
    case badHeaderLength
    case unsupportedVersion(major: UInt16, minor: UInt16)
    case unsupportedFlags
    case unrecognizedChunk(UInt32)
    case unsupportedFeature(String)
    case malformed(String)
    case outOfBounds
}

public struct QD3DPoint3D: Sendable, Equatable {
    public var x: Float
    public var y: Float
    public var z: Float
}

public struct QD3DParam2D: Sendable, Equatable {
    public var u: Float
    public var v: Float
}

public struct QD3DVector3D: Sendable, Equatable {
    public var x: Float
    public var y: Float
    public var z: Float
}

public struct QD3DColorRGBA: Sendable, Equatable {
    public var r: Float
    public var g: Float
    public var b: Float
    public var a: Float
}

public struct QD3DBoundingBox: Sendable, Equatable {
    public var min: QD3DPoint3D
    public var max: QD3DPoint3D
    public var isEmpty: Bool
}

public enum QD3DTexturingMode: Int32, Sendable, Equatable {
    case invalid = -1
    case off = 0
    case opaque = 1
    case alphaTest = 2
    case alphaBlend = 3
}

public enum QD3DPixelType: UInt32, Sendable, Equatable {
    case rgb32 = 0
    case argb32 = 1
    case rgb16 = 2
    case argb16 = 3
    case rgb16_565 = 4
    case rgb24 = 5
    case rgba32 = 6
}

public enum QD3DUVBoundary: UInt32, Sendable, Equatable {
    case wrap = 0
    case clamp = 1
}

public struct QD3DTriangle: Sendable, Equatable {
    public var v0: UInt32
    public var v1: UInt32
    public var v2: UInt32
}

public struct QD3DTriMesh: Sendable, Equatable {
    public var triangles: [QD3DTriangle]
    public var points: [QD3DPoint3D]
    public var vertexNormals: [QD3DVector3D]?
    public var vertexUVs: [QD3DParam2D]?
    public var vertexColors: [QD3DColorRGBA]?
    public var boundingBox: QD3DBoundingBox
    public var texturingMode: QD3DTexturingMode
    public var internalTextureID: Int // index into MetaFile3D.textures, or -1
    public var diffuseColor: QD3DColorRGBA
}

public struct QD3DPixmap: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var rowBytes: Int // trimmed to width * bytesPerPixel
    public var pixelSize: Int // bits per pixel
    public var pixelType: QD3DPixelType
    /// Row-major image bytes, trimmed of row padding. Multi-byte pixels are in
    /// the file's byte order (`byteOrder`); the GL layer swaps to host order.
    public var image: [UInt8]
    public var byteOrder: QD3DUVBoundary.RawValue // 0 = big, 1 = little
}

public struct QD3DTextureShader: Sendable, Equatable {
    public var pixmap: QD3DPixmap?
    public var boundaryU: QD3DUVBoundary
    public var boundaryV: QD3DUVBoundary
}

/// A parsed 3DMF metafile. `meshes` is the flat list of every TriMesh in the
/// file; `topLevelGroups` groups mesh indices into the file's top-level
/// objects (each group is one loadable model).
public struct MetaFile3D: Sendable, Equatable {
    public var textures: [QD3DTextureShader]
    public var meshes: [QD3DTriMesh]
    public var topLevelGroups: [[Int]] // indices into `meshes`

    public init(parsing3DMF data: some Sequence<UInt8>) throws {
        var parser = Q3MetaFileParser(Array(data))
        try parser.parse()
        self.textures = parser.textures
        self.meshes = parser.meshes
        self.topLevelGroups = parser.topLevelGroups
    }
}

// MARK: - Random-access big-endian byte cursor

private struct ByteCursor {
    let bytes: [UInt8]
    var offset = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var count: Int { bytes.count }

    mutating func readUInt8() throws -> UInt8 {
        guard offset < bytes.count else { throw QD3DParsingError.outOfBounds }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func readUInt16() throws -> UInt16 {
        let hi = try readUInt8(), lo = try readUInt8()
        return (UInt16(hi) << 8) | UInt16(lo)
    }

    mutating func readUInt32() throws -> UInt32 {
        let a = try readUInt16(), b = try readUInt16()
        return (UInt32(a) << 16) | UInt32(b)
    }

    mutating func readUInt64() throws -> UInt64 {
        let a = try readUInt32(), b = try readUInt32()
        return (UInt64(a) << 32) | UInt64(b)
    }

    mutating func readFloat() throws -> Float {
        Float(bitPattern: try readUInt32())
    }

    mutating func readBytes(_ n: Int) throws -> [UInt8] {
        guard n >= 0, offset + n <= bytes.count else { throw QD3DParsingError.outOfBounds }
        defer { offset += n }
        return Array(bytes[offset..<offset + n])
    }

    mutating func skip(_ n: Int) throws {
        guard offset + n <= bytes.count, offset + n >= 0 else { throw QD3DParsingError.outOfBounds }
        offset += n
    }

    mutating func seek(_ p: Int) throws {
        guard p >= 0, p <= bytes.count else { throw QD3DParsingError.outOfBounds }
        offset = p
    }
}

// MARK: - fourcc chunk tags

private enum FourCC {
    static let magic3DMF: UInt32 = 0x3344_4D46 // '3DMF'
    static let toc: UInt32 = 0x746F_6320       // 'toc '
    static let cntr: UInt32 = 0x636E_7472      // 'cntr'
    static let bgng: UInt32 = 0x6267_6E67      // 'bgng'
    static let endg: UInt32 = 0x656E_6467      // 'endg'
    static let tmsh: UInt32 = 0x746D_7368      // 'tmsh'
    static let atar: UInt32 = 0x6174_6172      // 'atar'
    static let attr: UInt32 = 0x6174_7472      // 'attr'
    static let kdif: UInt32 = 0x6B64_6966      // 'kdif'
    static let kxpr: UInt32 = 0x6B78_7072      // 'kxpr'
    static let txsu: UInt32 = 0x7478_7375      // 'txsu'
    static let txmm: UInt32 = 0x7478_6D6D      // 'txmm'
    static let txpm: UInt32 = 0x7478_706D      // 'txpm'
    static let shdr: UInt32 = 0x7368_6472      // 'shdr'
    static let rfrn: UInt32 = 0x7266_726E      // 'rfrn'
}

// QD3D attribute-array types (subset used by 'atar').
private enum AttributeType {
    static let surfaceUV: UInt32 = 1
    static let shadingUV: UInt32 = 2
    static let normal: UInt32 = 3
    static let diffuseColor: UInt32 = 5
    static let numTypes: UInt32 = 13
}

// MARK: - Parser (faithful port of Pomme's Q3MetaFileParser)

private struct Q3MetaFileParser {
    var cursor: ByteCursor

    var textures: [QD3DTextureShader] = []
    var meshes: [QD3DTriMesh] = []
    var topLevelGroups: [[Int]] = []

    private var currentDepth = 0
    private var currentMeshIndex: Int? // index into `meshes`
    private var referenceTOC: [UInt32: (offset: Int, type: UInt32)] = [:]
    private var knownTextures: [Int: Int] = [:] // chunk offset -> texture index

    init(_ bytes: [UInt8]) {
        cursor = ByteCursor(bytes)
    }

    mutating func parse() throws {
        let fileLength = cursor.count

        guard try cursor.readUInt32() == FourCC.magic3DMF else { throw QD3DParsingError.notA3DMF }
        guard try cursor.readUInt32() == 16 else { throw QD3DParsingError.badHeaderLength }
        let versionMajor = try cursor.readUInt16()
        let versionMinor = try cursor.readUInt16()
        guard versionMajor == 1, versionMinor == 5 || versionMinor == 6 else {
            throw QD3DParsingError.unsupportedVersion(major: versionMajor, minor: versionMinor)
        }
        guard try cursor.readUInt32() == 0 else { throw QD3DParsingError.unsupportedFlags }
        let tocOffset = try cursor.readUInt64()

        if tocOffset != 0 {
            let resume = cursor.offset
            try readTOC(at: Int(tocOffset))
            try cursor.seek(resume)
        }

        do {
            while cursor.offset != fileLength {
                _ = try parseChunk()
            }
        } catch EarlyEOF.signal {
            // Corrupted/early-terminated file (a zero chunk tag) - stop here,
            // matching the C++ parser's Q3MetaFile_EarlyEOFException.
        }
    }

    private mutating func readTOC(at offset: Int) throws {
        try cursor.seek(offset)
        guard try cursor.readUInt32() == FourCC.toc else { throw QD3DParsingError.malformed("expected toc") }
        try cursor.skip(4)  // tocSize
        try cursor.skip(8)  // nextToc
        try cursor.skip(4)  // refSeed
        try cursor.skip(4)  // typeSeed
        let tocEntryType = try cursor.readUInt32()
        let tocEntrySize = try cursor.readUInt32()
        let numEntries = try cursor.readUInt32()
        guard tocEntryType == 1 else { throw QD3DParsingError.malformed("unsupported TOC type") }
        guard tocEntrySize == 16 else { throw QD3DParsingError.malformed("bad TOC entry size") }
        for _ in 0..<numEntries {
            let refID = try cursor.readUInt32()
            let objLocation = try cursor.readUInt64()
            let objType = try cursor.readUInt32()
            referenceTOC[refID] = (offset: Int(objLocation), type: objType)
        }
    }

    private enum EarlyEOF: Error { case signal }

    @discardableResult
    private mutating func parseChunk() throws -> UInt32 {
        guard currentDepth >= 0 else { throw QD3DParsingError.malformed("depth underflow") }

        let chunkOffset = cursor.offset
        let chunkType = try cursor.readUInt32()
        let chunkSize = Int(try cursor.readUInt32())

        switch chunkType {
        case 0:
            throw EarlyEOF.signal

        case FourCC.cntr:
            if currentDepth == 1 { topLevelGroups.append([]) }
            currentDepth += 1
            let limit = cursor.offset + chunkSize
            while cursor.offset != limit {
                _ = try parseChunk()
            }
            currentDepth -= 1
            currentMeshIndex = nil

        case FourCC.bgng:
            if currentDepth == 1 { topLevelGroups.append([]) }
            currentDepth += 1
            try cursor.skip(chunkSize)
            while try parseChunk() != FourCC.endg {}
            currentDepth -= 1
            currentMeshIndex = nil

        case FourCC.endg:
            guard chunkSize == 0 else { throw QD3DParsingError.malformed("illegal endg size") }

        case FourCC.tmsh:
            guard currentMeshIndex == nil else { throw QD3DParsingError.malformed("nested meshes") }
            try parseTriMesh(chunkSize: chunkSize)
            if topLevelGroups.isEmpty { topLevelGroups.append([]) }
            topLevelGroups[topLevelGroups.count - 1].append(meshes.count - 1)

        case FourCC.atar:
            try parseAttributeArray(chunkSize: chunkSize)

        case FourCC.attr:
            guard chunkSize == 0 else { throw QD3DParsingError.malformed("illegal attr size") }

        case FourCC.kdif:
            guard chunkSize == 12, let mi = currentMeshIndex else { throw QD3DParsingError.malformed("stray kdif") }
            meshes[mi].diffuseColor.r = try cursor.readFloat()
            meshes[mi].diffuseColor.g = try cursor.readFloat()
            meshes[mi].diffuseColor.b = try cursor.readFloat()

        case FourCC.kxpr:
            guard chunkSize == 12, let mi = currentMeshIndex else { throw QD3DParsingError.malformed("stray kxpr") }
            let r = try cursor.readFloat()
            _ = try cursor.readFloat() // g
            _ = try cursor.readFloat() // b
            meshes[mi].diffuseColor.a = r

        case FourCC.txsu:
            guard chunkSize == 0 else { throw QD3DParsingError.malformed("illegal txsu size") }
            let textureID: Int
            if let known = knownTextures[chunkOffset] {
                textureID = known
            } else {
                textureID = textures.count
                textures.append(QD3DTextureShader(pixmap: nil, boundaryU: .wrap, boundaryV: .wrap))
                knownTextures[chunkOffset] = textureID
            }
            if let mi = currentMeshIndex {
                meshes[mi].internalTextureID = textureID
                meshes[mi].texturingMode = .invalid
            }

        case FourCC.txmm, FourCC.txpm:
            guard !textures.isEmpty else { throw QD3DParsingError.malformed("txmm/txpm without txsu") }
            if textures[textures.count - 1].pixmap != nil {
                try cursor.skip(chunkSize)
            } else {
                textures[textures.count - 1].pixmap = try parsePixmap(chunkType: chunkType, chunkSize: chunkSize)
            }

        case FourCC.shdr:
            guard chunkSize == 8, !textures.isEmpty else { throw QD3DParsingError.malformed("illegal shdr") }
            textures[textures.count - 1].boundaryU = QD3DUVBoundary(rawValue: try cursor.readUInt32()) ?? .wrap
            textures[textures.count - 1].boundaryV = QD3DUVBoundary(rawValue: try cursor.readUInt32()) ?? .wrap

        case FourCC.rfrn:
            guard chunkSize == 4 else { throw QD3DParsingError.malformed("illegal rfrn size") }
            let target = try cursor.readUInt32()
            guard let entry = referenceTOC[target] else { throw QD3DParsingError.malformed("bad rfrn target") }
            let resume = cursor.offset
            try cursor.seek(entry.offset)
            _ = try parseChunk()
            try cursor.seek(resume)

        case FourCC.toc:
            try cursor.skip(chunkSize)

        default:
            throw QD3DParsingError.unrecognizedChunk(chunkType)
        }

        return chunkType
    }

    private mutating func parseTriMesh(chunkSize: Int) throws {
        guard chunkSize >= 52 else { throw QD3DParsingError.malformed("illegal tmsh size") }

        let numTriangles = Int(try cursor.readUInt32())
        try cursor.skip(4) // numTriangleAttributes
        let numEdges = try cursor.readUInt32()
        let numEdgeAttributes = try cursor.readUInt32()
        let numVertices = Int(try cursor.readUInt32())
        try cursor.skip(4) // numVertexAttributes
        guard numEdges == 0, numEdgeAttributes == 0 else {
            throw QD3DParsingError.unsupportedFeature("edges")
        }

        // Triangle vertex indices - width depends on the vertex count.
        var triangles = [QD3DTriangle]()
        triangles.reserveCapacity(numTriangles)
        for _ in 0..<numTriangles {
            let v0: UInt32, v1: UInt32, v2: UInt32
            if numVertices <= 0xFF {
                v0 = UInt32(try cursor.readUInt8()); v1 = UInt32(try cursor.readUInt8()); v2 = UInt32(try cursor.readUInt8())
            } else if numVertices <= 0xFFFF {
                v0 = UInt32(try cursor.readUInt16()); v1 = UInt32(try cursor.readUInt16()); v2 = UInt32(try cursor.readUInt16())
            } else {
                v0 = try cursor.readUInt32(); v1 = try cursor.readUInt32(); v2 = try cursor.readUInt32()
            }
            guard v0 < numVertices, v1 < numVertices, v2 < numVertices else {
                throw QD3DParsingError.malformed("vertex index out of range")
            }
            triangles.append(QD3DTriangle(v0: v0, v1: v1, v2: v2))
        }

        // Vertices.
        var points = [QD3DPoint3D]()
        points.reserveCapacity(numVertices)
        for _ in 0..<numVertices {
            points.append(QD3DPoint3D(x: try cursor.readFloat(), y: try cursor.readFloat(), z: try cursor.readFloat()))
        }

        // Bounding box.
        let bMin = QD3DPoint3D(x: try cursor.readFloat(), y: try cursor.readFloat(), z: try cursor.readFloat())
        let bMax = QD3DPoint3D(x: try cursor.readFloat(), y: try cursor.readFloat(), z: try cursor.readFloat())
        let emptyFlag = try cursor.readUInt32()

        meshes.append(QD3DTriMesh(
            triangles: triangles,
            points: points,
            vertexNormals: nil,
            vertexUVs: nil,
            vertexColors: nil,
            boundingBox: QD3DBoundingBox(min: bMin, max: bMax, isEmpty: emptyFlag != 0),
            texturingMode: .off,
            internalTextureID: -1,
            diffuseColor: QD3DColorRGBA(r: 1, g: 1, b: 1, a: 1)))
        currentMeshIndex = meshes.count - 1
    }

    private mutating func parseAttributeArray(chunkSize: Int) throws {
        guard chunkSize >= 20, let mi = currentMeshIndex else { throw QD3DParsingError.malformed("stray atar") }

        let attributeType = try cursor.readUInt32()
        guard try cursor.readUInt32() == 0 else { throw QD3DParsingError.malformed("expected zero in atar") }
        let positionOfArray = try cursor.readUInt32()
        _ = try cursor.readUInt32() // positionInArray
        let attributeUseFlag = try cursor.readUInt32()

        guard attributeType >= 1, attributeType < AttributeType.numTypes else {
            throw QD3DParsingError.malformed("illegal attribute type")
        }
        guard positionOfArray <= 2, attributeUseFlag <= 1 else {
            throw QD3DParsingError.malformed("illegal atar layout")
        }

        let isTriangleAttribute = positionOfArray == 0
        let isVertexAttribute = positionOfArray == 2
        guard isTriangleAttribute || isVertexAttribute else {
            throw QD3DParsingError.unsupportedFeature("attribute position")
        }

        let numPoints = meshes[mi].points.count
        let numTriangles = meshes[mi].triangles.count

        if isVertexAttribute, attributeType == AttributeType.shadingUV || attributeType == AttributeType.surfaceUV {
            var uvs = [QD3DParam2D]()
            uvs.reserveCapacity(numPoints)
            for _ in 0..<numPoints {
                let u = try cursor.readFloat()
                let v = try cursor.readFloat()
                uvs.append(QD3DParam2D(u: u, v: 1 - v))
            }
            meshes[mi].vertexUVs = uvs
        } else if isVertexAttribute, attributeType == AttributeType.normal {
            var normals = [QD3DVector3D]()
            normals.reserveCapacity(numPoints)
            for _ in 0..<numPoints {
                normals.append(QD3DVector3D(x: try cursor.readFloat(), y: try cursor.readFloat(), z: try cursor.readFloat()))
            }
            meshes[mi].vertexNormals = normals
        } else if isVertexAttribute, attributeType == AttributeType.diffuseColor {
            var colors = [QD3DColorRGBA]()
            colors.reserveCapacity(numPoints)
            for _ in 0..<numPoints {
                colors.append(QD3DColorRGBA(r: try cursor.readFloat(), g: try cursor.readFloat(), b: try cursor.readFloat(), a: 1))
            }
            meshes[mi].vertexColors = colors
        } else if isTriangleAttribute, attributeType == AttributeType.normal {
            try cursor.skip(numTriangles * 3 * 4) // face normals - ignored
        } else {
            throw QD3DParsingError.unsupportedFeature("attribute combination")
        }
    }

    private mutating func parsePixmap(chunkType: UInt32, chunkSize: Int) throws -> QD3DPixmap {
        let chunkHeaderSize = chunkType == FourCC.txmm ? 8 * 4 : 7 * 4
        guard chunkSize >= chunkHeaderSize else { throw QD3DParsingError.malformed("bad pixmap header") }

        let pixelTypeRaw: UInt32
        let bitOrder: UInt32
        let byteOrder: UInt32
        let width: Int
        let height: Int
        let rowBytes: Int

        if chunkType == FourCC.txmm {
            let useMipmapping = try cursor.readUInt32()
            pixelTypeRaw = try cursor.readUInt32()
            bitOrder = try cursor.readUInt32()
            byteOrder = try cursor.readUInt32()
            width = Int(try cursor.readUInt32())
            height = Int(try cursor.readUInt32())
            rowBytes = Int(try cursor.readUInt32())
            let offset = try cursor.readUInt32()
            guard useMipmapping == 0 else { throw QD3DParsingError.unsupportedFeature("mipmapping") }
            guard offset == 0 else { throw QD3DParsingError.unsupportedFeature("texture offset") }
        } else {
            width = Int(try cursor.readUInt32())
            height = Int(try cursor.readUInt32())
            rowBytes = Int(try cursor.readUInt32())
            try cursor.skip(4) // pixelSize
            pixelTypeRaw = try cursor.readUInt32()
            bitOrder = try cursor.readUInt32()
            byteOrder = try cursor.readUInt32()
        }

        var imageSize = rowBytes * height
        if imageSize & 3 != 0 { imageSize = (imageSize & ~3) + 4 }
        guard chunkSize == chunkHeaderSize + imageSize else { throw QD3DParsingError.malformed("bad pixmap size") }
        guard bitOrder == 0 else { throw QD3DParsingError.unsupportedFeature("bit order") } // kQ3EndianBig

        guard let pixelType = QD3DPixelType(rawValue: pixelTypeRaw) else {
            throw QD3DParsingError.unsupportedFeature("pixel type \(pixelTypeRaw)")
        }
        let bytesPerPixel: Int
        switch pixelType {
        case .rgb16, .argb16: bytesPerPixel = 2
        case .rgb32, .argb32: bytesPerPixel = 4
        default: throw QD3DParsingError.unsupportedFeature("pixel type \(pixelTypeRaw)")
        }

        let trimmedRowBytes = bytesPerPixel * width
        var image = [UInt8]()
        image.reserveCapacity(trimmedRowBytes * height)
        for _ in 0..<height {
            image.append(contentsOf: try cursor.readBytes(trimmedRowBytes))
            try cursor.skip(rowBytes - width * bytesPerPixel)
        }

        return QD3DPixmap(
            width: width,
            height: height,
            rowBytes: trimmedRowBytes,
            pixelSize: bytesPerPixel * 8,
            pixelType: pixelType,
            image: image,
            byteOrder: byteOrder == 1 ? 1 : 0)
    }
}
