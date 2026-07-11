// Renderer.swift - Draws QD3DFile models with OpenGL: client-side
// vertex/normal/UV arrays submitted with glDrawElements (the approach from
// src/QD3D/Renderer.c and the Pangea book, Ch.6), with textures uploaded from
// the parsed pixmaps. Meshes draw textured + lit where UVs/textures exist, else
// shaded by their diffuse color.
import COpenGL
import QD3DFile
import QD3DMath

/// A GL texture uploaded from a parsed QD3DPixmap. Owns the GL texture name.
public final class Texture2D {
    public let name: GLuint

    public convenience init?(_ pixmap: QD3DPixmap) {
        guard pixmap.width > 0, pixmap.height > 0 else { return nil }
        self.init(rgba: Texture2D.toRGBA(pixmap), width: pixmap.width, height: pixmap.height)
    }

    /// Uploads raw RGBA pixels as a GL texture (used by the terrain atlas).
    public init?(rgba: [UInt8], width: Int, height: Int) {
        guard width > 0, height > 0 else { return nil }

        var n: GLuint = 0
        glGenTextures(1, &n)
        guard n != 0 else { return nil }
        glBindTexture(GLenum(GL_TEXTURE_2D), n)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_LINEAR)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GL_LINEAR)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GL_REPEAT)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GL_REPEAT)
        glPixelStorei(GLenum(GL_UNPACK_ALIGNMENT), 1)
        rgba.withUnsafeBytes { buf in
            glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GLint(GL_RGBA),
                         GLsizei(width), GLsizei(height), 0,
                         GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), buf.baseAddress)
        }
        name = n
    }

    deinit {
        var n = name
        glDeleteTextures(1, &n)
    }

    /// Converts a pixmap to 8-bit RGBA. Handles the 16-bit 1-5-5-5 and 32-bit
    /// ARGB/RGB formats the game ships, honoring the stored byte order.
    static func toRGBA(_ p: QD3DPixmap) -> [UInt8] {
        let count = p.width * p.height
        var out = [UInt8](repeating: 0, count: count * 4)
        let img = p.image
        let little = p.byteOrder == 1

        func expand5(_ v: UInt16) -> UInt8 { UInt8((Int(v) * 255) / 31) }

        switch p.pixelType {
        case .rgb16, .argb16:
            for i in 0..<count {
                let b0 = UInt16(img[i * 2]), b1 = UInt16(img[i * 2 + 1])
                let v = little ? (b0 | (b1 << 8)) : ((b0 << 8) | b1)
                out[i * 4 + 0] = expand5((v >> 10) & 0x1F)
                out[i * 4 + 1] = expand5((v >> 5) & 0x1F)
                out[i * 4 + 2] = expand5(v & 0x1F)
                out[i * 4 + 3] = p.pixelType == .argb16 ? (((v >> 15) & 1) != 0 ? 255 : 0) : 255
            }
        case .rgba32:
            for i in 0..<count {
                out[i * 4 + 0] = img[i * 4 + 0]; out[i * 4 + 1] = img[i * 4 + 1]
                out[i * 4 + 2] = img[i * 4 + 2]; out[i * 4 + 3] = img[i * 4 + 3]
            }
        default: // argb32 / rgb32: bytes are A,R,G,B big-endian (X,R,G,B for rgb32)
            for i in 0..<count {
                let a = little ? img[i * 4 + 3] : img[i * 4 + 0]
                let r = little ? img[i * 4 + 2] : img[i * 4 + 1]
                let g = little ? img[i * 4 + 1] : img[i * 4 + 2]
                let b = little ? img[i * 4 + 0] : img[i * 4 + 3]
                out[i * 4 + 0] = r; out[i * 4 + 1] = g; out[i * 4 + 2] = b
                out[i * 4 + 3] = p.pixelType == .rgb32 ? 255 : a
            }
        }
        return out
    }
}

/// A QD3DTriMesh flattened into contiguous, GL-ready arrays. Owns its buffers
/// (stable pointers) so vertex-array pointers stay valid across frames.
public final class RenderableMesh {
    let points: UnsafeMutableBufferPointer<Float>   // 3 per vertex
    let normals: UnsafeMutableBufferPointer<Float>? // 3 per vertex, or nil
    let uvs: UnsafeMutableBufferPointer<Float>?     // 2 per vertex, or nil
    let indices: UnsafeMutableBufferPointer<UInt32> // 3 per triangle
    let diffuse: (Float, Float, Float, Float)
    let textureName: GLuint // 0 if none
    /// Real bounds computed from the vertices (the stored 3DMF bboxes are
    /// unreliable), used to frame the camera.
    public let boundsMin: Point3D
    public let boundsMax: Point3D

    public init(_ mesh: QD3DTriMesh, textureName: GLuint = 0) {
        self.textureName = textureName
        diffuse = (mesh.diffuseColor.r, mesh.diffuseColor.g, mesh.diffuseColor.b, mesh.diffuseColor.a)

        var lo = Point3D(x: .greatestFiniteMagnitude, y: .greatestFiniteMagnitude, z: .greatestFiniteMagnitude)
        var hi = Point3D(x: -.greatestFiniteMagnitude, y: -.greatestFiniteMagnitude, z: -.greatestFiniteMagnitude)
        points = .allocate(capacity: mesh.points.count * 3)
        for (i, p) in mesh.points.enumerated() {
            points[i * 3 + 0] = p.x; points[i * 3 + 1] = p.y; points[i * 3 + 2] = p.z
            lo.x = min(lo.x, p.x); lo.y = min(lo.y, p.y); lo.z = min(lo.z, p.z)
            hi.x = max(hi.x, p.x); hi.y = max(hi.y, p.y); hi.z = max(hi.z, p.z)
        }
        boundsMin = lo
        boundsMax = hi

        if let ns = mesh.vertexNormals, ns.count == mesh.points.count {
            let buf = UnsafeMutableBufferPointer<Float>.allocate(capacity: ns.count * 3)
            for (i, n) in ns.enumerated() { buf[i * 3 + 0] = n.x; buf[i * 3 + 1] = n.y; buf[i * 3 + 2] = n.z }
            normals = buf
        } else { normals = nil }

        if let us = mesh.vertexUVs, us.count == mesh.points.count {
            let buf = UnsafeMutableBufferPointer<Float>.allocate(capacity: us.count * 2)
            for (i, uv) in us.enumerated() { buf[i * 2 + 0] = uv.u; buf[i * 2 + 1] = uv.v }
            uvs = buf
        } else { uvs = nil }

        indices = .allocate(capacity: mesh.triangles.count * 3)
        for (i, t) in mesh.triangles.enumerated() {
            indices[i * 3 + 0] = t.v0; indices[i * 3 + 1] = t.v1; indices[i * 3 + 2] = t.v2
        }
    }

    /// Build directly from flat GL-ready arrays (used by the terrain builder).
    public init(points p: [Float], normals nn: [Float]?, uvs uu: [Float]?,
                indices ii: [UInt32], textureName: GLuint = 0,
                diffuse: (Float, Float, Float, Float) = (1, 1, 1, 1)) {
        self.textureName = textureName
        self.diffuse = diffuse

        var lo = Point3D(x: .greatestFiniteMagnitude, y: .greatestFiniteMagnitude, z: .greatestFiniteMagnitude)
        var hi = Point3D(x: -.greatestFiniteMagnitude, y: -.greatestFiniteMagnitude, z: -.greatestFiniteMagnitude)
        var i = 0
        while i + 2 < p.count {
            lo.x = min(lo.x, p[i]); hi.x = max(hi.x, p[i])
            lo.y = min(lo.y, p[i + 1]); hi.y = max(hi.y, p[i + 1])
            lo.z = min(lo.z, p[i + 2]); hi.z = max(hi.z, p[i + 2])
            i += 3
        }
        boundsMin = lo
        boundsMax = hi

        points = .allocate(capacity: p.count)
        _ = points.initialize(from: p)
        if let nn {
            let buf = UnsafeMutableBufferPointer<Float>.allocate(capacity: nn.count)
            _ = buf.initialize(from: nn); normals = buf
        } else { normals = nil }
        if let uu {
            let buf = UnsafeMutableBufferPointer<Float>.allocate(capacity: uu.count)
            _ = buf.initialize(from: uu); uvs = buf
        } else { uvs = nil }
        indices = .allocate(capacity: ii.count)
        _ = indices.initialize(from: ii)
    }

    deinit {
        points.deallocate(); normals?.deallocate(); uvs?.deallocate(); indices.deallocate()
    }

    /// Overwrite the vertex positions/normals with freshly deformed geometry
    /// (used each frame by the skeleton animator).
    public func updateGeometry(points newPoints: [Float], normals newNormals: [Float]) {
        let pc = min(newPoints.count, points.count)
        for i in 0..<pc { points[i] = newPoints[i] }
        if let normals {
            let nc = min(newNormals.count, normals.count)
            for i in 0..<nc { normals[i] = newNormals[i] }
        }
    }

    /// Center + radius of the bounding sphere over several meshes, for framing.
    public static func bounds(of meshes: [RenderableMesh]) -> (center: Point3D, radius: Float) {
        guard !meshes.isEmpty else { return (Point3D(), 1) }
        var lo = Point3D(x: .greatestFiniteMagnitude, y: .greatestFiniteMagnitude, z: .greatestFiniteMagnitude)
        var hi = Point3D(x: -.greatestFiniteMagnitude, y: -.greatestFiniteMagnitude, z: -.greatestFiniteMagnitude)
        for m in meshes {
            lo.x = min(lo.x, m.boundsMin.x); lo.y = min(lo.y, m.boundsMin.y); lo.z = min(lo.z, m.boundsMin.z)
            hi.x = max(hi.x, m.boundsMax.x); hi.y = max(hi.y, m.boundsMax.y); hi.z = max(hi.z, m.boundsMax.z)
        }
        let center = Point3D(x: (lo.x + hi.x) / 2, y: (lo.y + hi.y) / 2, z: (lo.z + hi.z) / 2)
        let dx = hi.x - lo.x, dy = hi.y - lo.y, dz = hi.z - lo.z
        return (center, max(1, (dx * dx + dy * dy + dz * dz).squareRoot() / 2))
    }
}

/// A whole model: its GL textures plus its meshes. Keeps the textures alive for
/// as long as the meshes reference them.
public final class RenderableModel {
    public let textures: [Texture2D]
    public let meshes: [RenderableMesh]
    /// Top-level object groups (each is a list of indices into `meshes`), so a
    /// single loaded file can be drawn as separate objects (trees, rocks, ...).
    public let objects: [[Int]]

    public init(_ file: MetaFile3D) {
        objects = file.topLevelGroups
        var texObjects: [Texture2D] = []
        var names: [GLuint] = [] // aligned to file.textures
        for shader in file.textures {
            if let pm = shader.pixmap, let tex = Texture2D(pm) {
                texObjects.append(tex); names.append(tex.name)
            } else {
                names.append(0)
            }
        }
        textures = texObjects
        meshes = file.meshes.map { mesh in
            let id = mesh.internalTextureID
            let name: GLuint = (id >= 0 && id < names.count) ? names[id] : 0
            return RenderableMesh(mesh, textureName: name)
        }
    }
}

public struct Renderer {
    public init() {}

    public func setCamera(eye: Point3D, center: Point3D, up: Vector3D,
                          aspect: Float, fovYDegrees: Float = 60,
                          near: Float, far: Float) {
        glMatrixMode(GLenum(GL_PROJECTION))
        glLoadMatrixf(glPerspective(fovYDegrees: fovYDegrees, aspect: aspect, near: near, far: far))
        glMatrixMode(GLenum(GL_MODELVIEW))
        glLoadMatrixf(glLookAt(eye: eye, center: center, up: up))
    }

    public func enableBasicLighting() {
        glEnable(GLenum(GL_LIGHTING))
        glEnable(GLenum(GL_LIGHT0))
        glEnable(GLenum(GL_COLOR_MATERIAL))
        glEnable(GLenum(GL_NORMALIZE))
        glTexEnvi(GLenum(GL_TEXTURE_ENV), GLenum(GL_TEXTURE_ENV_MODE), GLint(GL_MODULATE))
        var lightDir: [Float] = [0.4, 0.7, 1.0, 0.0]
        glLightfv(GLenum(GL_LIGHT0), GLenum(GL_POSITION), &lightDir)
        var ambient: [Float] = [0.35, 0.35, 0.35, 1.0]
        glLightfv(GLenum(GL_LIGHT0), GLenum(GL_AMBIENT), &ambient)
    }

    public func draw(_ mesh: RenderableMesh, transform: Matrix4x4) {
        glPushMatrix()
        glMultMatrixf(transform.glArray)

        let textured = mesh.textureName != 0 && mesh.uvs != nil
        if textured {
            glEnable(GLenum(GL_TEXTURE_2D))
            glBindTexture(GLenum(GL_TEXTURE_2D), mesh.textureName)
            glColor4f(1, 1, 1, 1) // modulate: let the texture show through
        } else {
            glDisable(GLenum(GL_TEXTURE_2D))
            glColor4f(mesh.diffuse.0, mesh.diffuse.1, mesh.diffuse.2, mesh.diffuse.3)
        }

        glEnableClientState(GLenum(GL_VERTEX_ARRAY))
        glVertexPointer(3, GLenum(GL_FLOAT), 0, mesh.points.baseAddress)

        if let normals = mesh.normals {
            glEnableClientState(GLenum(GL_NORMAL_ARRAY))
            glNormalPointer(GLenum(GL_FLOAT), 0, normals.baseAddress)
        }
        if textured, let uvs = mesh.uvs {
            glEnableClientState(GLenum(GL_TEXTURE_COORD_ARRAY))
            glTexCoordPointer(2, GLenum(GL_FLOAT), 0, uvs.baseAddress)
        }

        glDrawElements(GLenum(GL_TRIANGLES), GLsizei(mesh.indices.count),
                       GLenum(GL_UNSIGNED_INT), mesh.indices.baseAddress)

        glDisableClientState(GLenum(GL_VERTEX_ARRAY))
        if mesh.normals != nil { glDisableClientState(GLenum(GL_NORMAL_ARRAY)) }
        if textured { glDisableClientState(GLenum(GL_TEXTURE_COORD_ARRAY)) }
        glPopMatrix()
    }
}
