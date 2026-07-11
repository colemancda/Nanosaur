// Renderer.swift - Draws QD3DFile TriMeshes with OpenGL, ported from the
// vertex-array drawing approach in src/QD3D/Renderer.c (and the Pangea book,
// Ch.6): client-side vertex/normal/UV arrays submitted with glDrawElements.
// Textures come later; for now meshes draw shaded by their diffuse color under
// a single directional light so model shape is visible.
import COpenGL
import QD3DFile
import QD3DMath

/// A QD3DTriMesh flattened into contiguous, GL-ready arrays. Owns its buffers
/// (stable pointers) so vertex-array pointers stay valid across frames.
public final class RenderableMesh {
    let points: UnsafeMutableBufferPointer<Float>   // 3 per vertex
    let normals: UnsafeMutableBufferPointer<Float>? // 3 per vertex, or nil
    let indices: UnsafeMutableBufferPointer<UInt32> // 3 per triangle
    let vertexCount: Int
    let diffuse: (Float, Float, Float, Float)
    public let boundingBox: QD3DBoundingBox

    public init(_ mesh: QD3DTriMesh) {
        vertexCount = mesh.points.count
        boundingBox = mesh.boundingBox
        diffuse = (mesh.diffuseColor.r, mesh.diffuseColor.g, mesh.diffuseColor.b, mesh.diffuseColor.a)

        points = .allocate(capacity: mesh.points.count * 3)
        for (i, p) in mesh.points.enumerated() {
            points[i * 3 + 0] = p.x; points[i * 3 + 1] = p.y; points[i * 3 + 2] = p.z
        }

        if let ns = mesh.vertexNormals, ns.count == mesh.points.count {
            let buf = UnsafeMutableBufferPointer<Float>.allocate(capacity: ns.count * 3)
            for (i, n) in ns.enumerated() {
                buf[i * 3 + 0] = n.x; buf[i * 3 + 1] = n.y; buf[i * 3 + 2] = n.z
            }
            normals = buf
        } else {
            normals = nil
        }

        indices = .allocate(capacity: mesh.triangles.count * 3)
        for (i, t) in mesh.triangles.enumerated() {
            indices[i * 3 + 0] = t.v0; indices[i * 3 + 1] = t.v1; indices[i * 3 + 2] = t.v2
        }
    }

    deinit {
        points.deallocate()
        normals?.deallocate()
        indices.deallocate()
    }

    /// Combined bounding box of several meshes, and a radius/center to frame a
    /// camera on the whole model.
    public static func bounds(of meshes: [RenderableMesh]) -> (center: Point3D, radius: Float) {
        guard !meshes.isEmpty else { return (Point3D(), 1) }
        var lo = Point3D(x: .greatestFiniteMagnitude, y: .greatestFiniteMagnitude, z: .greatestFiniteMagnitude)
        var hi = Point3D(x: -.greatestFiniteMagnitude, y: -.greatestFiniteMagnitude, z: -.greatestFiniteMagnitude)
        for m in meshes {
            lo.x = min(lo.x, m.boundingBox.min.x); lo.y = min(lo.y, m.boundingBox.min.y); lo.z = min(lo.z, m.boundingBox.min.z)
            hi.x = max(hi.x, m.boundingBox.max.x); hi.y = max(hi.y, m.boundingBox.max.y); hi.z = max(hi.z, m.boundingBox.max.z)
        }
        let center = Point3D(x: (lo.x + hi.x) / 2, y: (lo.y + hi.y) / 2, z: (lo.z + hi.z) / 2)
        let dx = hi.x - lo.x, dy = hi.y - lo.y, dz = hi.z - lo.z
        let radius = max(1, (dx * dx + dy * dy + dz * dz).squareRoot() / 2)
        return (center, radius)
    }
}

public struct Renderer {
    public init() {}

    /// Set the projection + view matrices for a perspective camera.
    public func setCamera(eye: Point3D, center: Point3D, up: Vector3D,
                          aspect: Float, fovYDegrees: Float = 60,
                          near: Float, far: Float) {
        glMatrixMode(GLenum(GL_PROJECTION))
        glLoadMatrixf(glPerspective(fovYDegrees: fovYDegrees, aspect: aspect, near: near, far: far))
        glMatrixMode(GLenum(GL_MODELVIEW))
        glLoadMatrixf(glLookAt(eye: eye, center: center, up: up))
    }

    /// One directional light so shaded geometry reads as 3D.
    public func enableBasicLighting() {
        glEnable(GLenum(GL_LIGHTING))
        glEnable(GLenum(GL_LIGHT0))
        glEnable(GLenum(GL_COLOR_MATERIAL))
        glEnable(GLenum(GL_NORMALIZE))
        var lightDir: [Float] = [0.4, 0.7, 1.0, 0.0] // directional (w=0)
        glLightfv(GLenum(GL_LIGHT0), GLenum(GL_POSITION), &lightDir)
        var ambient: [Float] = [0.3, 0.3, 0.3, 1.0]
        glLightfv(GLenum(GL_LIGHT0), GLenum(GL_AMBIENT), &ambient)
    }

    /// Draw one mesh under the given model transform.
    public func draw(_ mesh: RenderableMesh, transform: Matrix4x4) {
        glPushMatrix()
        glMultMatrixf(transform.glArray)

        glColor4f(mesh.diffuse.0, mesh.diffuse.1, mesh.diffuse.2, mesh.diffuse.3)

        glEnableClientState(GLenum(GL_VERTEX_ARRAY))
        glVertexPointer(3, GLenum(GL_FLOAT), 0, mesh.points.baseAddress)

        if let normals = mesh.normals {
            glEnableClientState(GLenum(GL_NORMAL_ARRAY))
            glNormalPointer(GLenum(GL_FLOAT), 0, normals.baseAddress)
        }

        glDrawElements(GLenum(GL_TRIANGLES), GLsizei(mesh.indices.count),
                       GLenum(GL_UNSIGNED_INT), mesh.indices.baseAddress)

        glDisableClientState(GLenum(GL_VERTEX_ARRAY))
        if mesh.normals != nil {
            glDisableClientState(GLenum(GL_NORMAL_ARRAY))
        }
        glPopMatrix()
    }
}
