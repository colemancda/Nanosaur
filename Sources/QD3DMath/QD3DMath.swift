// QD3DMath.swift - Core 3D vector/matrix types and math routines, ported from
// src/QD3D/3DMath.c plus the QuickDraw-3D vector primitives the game relies on
// (Q3Vector3D_Normalize/Dot/Cross, Q3Point3D_Transform, ...). These are the
// canonical geometry types the Swift engine is built on.
//
// Two routines from 3DMath.c that take an ObjNode (TurnObjectTowardTarget,
// CalcPointOnObject) are deferred until the object system exists.
import Foundation

public let pi2: Float = .pi * 2

// MARK: - Vector / point types

public struct Vector2D: Sendable, Equatable {
    public var x: Float
    public var y: Float
    public init(x: Float = 0, y: Float = 0) { self.x = x; self.y = y }
}

public struct Vector3D: Sendable, Equatable {
    public var x: Float
    public var y: Float
    public var z: Float
    public init(x: Float = 0, y: Float = 0, z: Float = 0) { self.x = x; self.y = y; self.z = z }
}

public struct Point2D: Sendable, Equatable {
    public var x: Float
    public var y: Float
    public init(x: Float = 0, y: Float = 0) { self.x = x; self.y = y }
}

public struct Point3D: Sendable, Equatable {
    public var x: Float
    public var y: Float
    public var z: Float
    public init(x: Float = 0, y: Float = 0, z: Float = 0) { self.x = x; self.y = y; self.z = z }
}

/// UV coordinate (TQ3Param2D).
public struct Param2D: Sendable, Equatable {
    public var u: Float
    public var v: Float
    public init(u: Float = 0, v: Float = 0) { self.u = u; self.v = v }
}

public struct PlaneEquation: Sendable, Equatable {
    public var normal: Vector3D
    public var constant: Float
    public init(normal: Vector3D = Vector3D(), constant: Float = 0) {
        self.normal = normal
        self.constant = constant
    }
}

public struct BoundingBox: Sendable, Equatable {
    public var min: Point3D
    public var max: Point3D
    public var isEmpty: Bool
    public init(min: Point3D = Point3D(), max: Point3D = Point3D(), isEmpty: Bool = true) {
        self.min = min
        self.max = max
        self.isEmpty = isEmpty
    }
}

/// 4x4 matrix (row-major, `value[row][col]`), matching TQ3Matrix4x4.
public struct Matrix4x4: Sendable, Equatable {
    public var value: [[Float]] // 4x4

    public init(value: [[Float]]) { self.value = value }

    public static let identity = Matrix4x4(value: [
        [1, 0, 0, 0],
        [0, 1, 0, 0],
        [0, 0, 1, 0],
        [0, 0, 0, 1],
    ])

    public init() { self = .identity }

    /// Matrix product `self * other` (QuickDraw 3D row-vector convention).
    public func multiplied(by other: Matrix4x4) -> Matrix4x4 {
        var result = [[Float]](repeating: [Float](repeating: 0, count: 4), count: 4)
        for i in 0..<4 {
            for j in 0..<4 {
                var sum: Float = 0
                for k in 0..<4 {
                    sum += value[i][k] * other.value[k][j]
                }
                result[i][j] = sum
            }
        }
        return Matrix4x4(value: result)
    }

    // Single-transform builders (QuickDraw 3D row-vector rotation matrices:
    // point' = point * M), matching Q3Matrix4x4_Set{Scale,Translate,Rotate_*}.

    public static func scale(_ x: Float, _ y: Float, _ z: Float) -> Matrix4x4 {
        Matrix4x4(value: [[x, 0, 0, 0], [0, y, 0, 0], [0, 0, z, 0], [0, 0, 0, 1]])
    }

    public static func translate(_ x: Float, _ y: Float, _ z: Float) -> Matrix4x4 {
        Matrix4x4(value: [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [x, y, z, 1]])
    }

    public static func rotationX(_ a: Float) -> Matrix4x4 {
        let c = cos(a), s = sin(a)
        return Matrix4x4(value: [[1, 0, 0, 0], [0, c, s, 0], [0, -s, c, 0], [0, 0, 0, 1]])
    }

    public static func rotationY(_ a: Float) -> Matrix4x4 {
        let c = cos(a), s = sin(a)
        return Matrix4x4(value: [[c, 0, -s, 0], [0, 1, 0, 0], [s, 0, c, 0], [0, 0, 0, 1]])
    }

    public static func rotationZ(_ a: Float) -> Matrix4x4 {
        let c = cos(a), s = sin(a)
        return Matrix4x4(value: [[c, s, 0, 0], [-s, c, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]])
    }

    /// Combined X-then-Y-then-Z rotation (Q3Matrix4x4_SetRotate_XYZ).
    public static func rotationXYZ(_ x: Float, _ y: Float, _ z: Float) -> Matrix4x4 {
        rotationX(x).multiplied(by: rotationY(y)).multiplied(by: rotationZ(z))
    }

    /// The 16 floats to hand to glLoadMatrixf/glMultMatrixf so OpenGL applies
    /// this exact transform. Our matrices use the row-vector convention
    /// (point' = point * M); OpenGL applies a loaded (column-major) matrix as
    /// M·v on column vectors. Working that through, GL's column-major storage
    /// of the equivalent map is precisely this matrix's row-major flattening.
    public var glArray: [Float] {
        value.flatMap { $0 }
    }
}

// MARK: - GL camera matrices (column-major, ready for glLoadMatrixf)

/// gluPerspective: column-major perspective projection matrix.
public func glPerspective(fovYDegrees: Float, aspect: Float, near: Float, far: Float) -> [Float] {
    let f = 1 / tan(fovYDegrees * .pi / 180 / 2)
    var m = [Float](repeating: 0, count: 16)
    m[0] = f / aspect
    m[5] = f
    m[10] = (far + near) / (near - far)
    m[11] = -1
    m[14] = (2 * far * near) / (near - far)
    return m
}

/// gluLookAt: column-major view matrix looking from `eye` toward `center`.
public func glLookAt(eye: Point3D, center: Point3D, up: Vector3D) -> [Float] {
    let f = Vector3D(x: center.x - eye.x, y: center.y - eye.y, z: center.z - eye.z).normalized()
    let s = f.cross(up).normalized()
    let u = s.cross(f)
    return [
        s.x, u.x, -f.x, 0,
        s.y, u.y, -f.y, 0,
        s.z, u.z, -f.z, 0,
        -(s.x * eye.x + s.y * eye.y + s.z * eye.z),
        -(u.x * eye.x + u.y * eye.y + u.z * eye.z),
        (f.x * eye.x + f.y * eye.y + f.z * eye.z),
        1,
    ]
}

// MARK: - Vector primitives (Q3Vector*/Q3Point*)

extension Vector2D {
    public var length: Float { (x * x + y * y).squareRoot() }
    public func normalized() -> Vector2D {
        let len = length
        guard len > 0 else { return self }
        return Vector2D(x: x / len, y: y / len)
    }
    public func dot(_ o: Vector2D) -> Float { x * o.x + y * o.y }
}

extension Vector3D {
    public var length: Float { (x * x + y * y + z * z).squareRoot() }
    public func normalized() -> Vector3D {
        let len = length
        guard len > 0 else { return self }
        return Vector3D(x: x / len, y: y / len, z: z / len)
    }
    public func dot(_ o: Vector3D) -> Float { x * o.x + y * o.y + z * o.z }
    public func cross(_ o: Vector3D) -> Vector3D {
        Vector3D(
            x: y * o.z - z * o.y,
            y: z * o.x - x * o.z,
            z: x * o.y - y * o.x)
    }
}

extension Point3D {
    /// Q3Point3D_Transform: treat the point as a row vector with implicit w=1
    /// and multiply by the 4x4 matrix.
    public func transformed(by m: Matrix4x4) -> Point3D {
        Point3D(
            x: x * m.value[0][0] + y * m.value[1][0] + z * m.value[2][0] + m.value[3][0],
            y: x * m.value[0][1] + y * m.value[1][1] + z * m.value[2][1] + m.value[3][1],
            z: x * m.value[0][2] + y * m.value[1][2] + z * m.value[2][2] + m.value[3][2])
    }
}

// MARK: - 3DMath.c routines

/// Limits an arbitrary angle to the range [0, 2*PI).
public func maskAngle(_ angle: Float) -> Float {
    let neg = angle < 0
    let n = Int(angle * (1.0 / pi2)) // how many full wraps
    var result = angle - Float(n) * pi2
    if neg { result += pi2 }
    return result
}

public func calcXAngleFromPointToPoint(fromY: Float, fromZ: Float, toY: Float, toZ: Float) -> Float {
    let zdiff = abs(toZ - fromZ)
    let xangle = atan2(-zdiff, toY - fromY) + (.pi / 2)
    return maskAngle(xangle)
}

/// Returns an unsigned result from 0 -> 2*PI.
public func calcYAngleFromPointToPoint(fromX: Float, fromZ: Float, toX: Float, toZ: Float) -> Float {
    pi2 - maskAngle(atan2(fromZ - toZ, fromX - toX) - (.pi / 2))
}

/// Angle between two vectors, projected onto the XZ plane.
public func calcYAngleBetweenVectors(_ v1: Vector3D, _ v2: Vector3D) -> Float {
    var a = v1, b = v2
    a.y = 0
    b.y = 0
    a = a.normalized()
    b = b.normalized()
    return acos(a.dot(b))
}

public func calcAngleBetweenVectors2D(_ v1: Vector2D, _ v2: Vector2D) -> Float {
    acos(v1.normalized().dot(v2.normalized()))
}

public func calcAngleBetweenVectors3D(_ v1: Vector3D, _ v2: Vector3D) -> Float {
    acos(v1.normalized().dot(v2.normalized()))
}

/// Cheap approximate distance between two 2D points.
public func calcQuickDistance(_ x1: Float, _ y1: Float, _ x2: Float, _ y2: Float) -> Float {
    let diffX = abs(x1 - x2)
    let diffY = abs(y1 - y2)
    return diffX > diffY ? diffX + 0.375 * diffY : diffY + 0.375 * diffX
}

/// Normal vector of the face defined by 3 points.
public func calcFaceNormal(_ p1: Point3D, _ p2: Point3D, _ p3: Point3D) -> Vector3D {
    let v1 = Vector3D(x: p1.x - p3.x, y: p1.y - p3.y, z: p1.z - p3.z)
    let v2 = Vector3D(x: p2.x - p3.x, y: p2.y - p3.y, z: p2.z - p3.z)
    return v1.cross(v2).normalized()
}

/// Precomputed XYZ rotation matrix (matches SetQuickRotationMatrix_XYZ).
public func quickRotationMatrixXYZ(rx: Float, ry: Float, rz: Float) -> Matrix4x4 {
    let sx = sin(rx), sy = sin(ry), sz = sin(rz)
    let cx = cos(rx), cy = cos(ry), cz = cos(rz)
    let sxsy = sx * sy, cxsy = cx * sy
    return Matrix4x4(value: [
        [cy * cz, cy * sz, -sy, 0],
        [(sxsy * cz) + (cx * -sz), (sxsy * sz) + (cx * cz), sx * cy, 0],
        [(cxsy * cz) + (-sx * -sz), (cxsy * sz) + (-sx * cz), cx * cy, 0],
        [0, 0, 0, 1],
    ])
}

/// Plane equation of a triangle (input points should be clockwise). Mirrors
/// CalcPlaneEquationOfTriangle's `(p3, p2, p1)` argument order.
public func calcPlaneEquationOfTriangle(_ p3: Point3D, _ p2: Point3D, _ p1: Point3D) -> PlaneEquation {
    let pq = Vector3D(x: p1.x - p2.x, y: p1.y - p2.y, z: p1.z - p2.z)
    let pr = Vector3D(x: p1.x - p3.x, y: p1.y - p3.y, z: p1.z - p3.z)
    let normal = Vector3D(
        x: (pq.y * pr.z) - (pq.z * pr.y),
        y: (pq.z * pr.x) - (pq.x * pr.z),
        z: (pq.x * pr.y) - (pq.y * pr.x)).normalized()
    let constant = normal.x * p1.x + normal.y * p1.y + normal.z * p1.z
    return PlaneEquation(normal: normal, constant: constant)
}

public func vectorsAreCloseEnough(_ v1: Vector3D, _ v2: Vector3D) -> Bool {
    abs(v1.x - v2.x) < 0.02 && abs(v1.y - v2.y) < 0.02 && abs(v1.z - v2.z) < 0.02
}

public func pointsAreCloseEnough(_ v1: Point3D, _ v2: Point3D) -> Bool {
    abs(v1.x - v2.x) < 0.001 && abs(v1.y - v2.y) < 0.001 && abs(v1.z - v2.z) < 0.001
}

/// Normalized (vx, vy, vz) (FastNormalizeVector's portable path).
public func fastNormalizeVector(_ vx: Float, _ vy: Float, _ vz: Float) -> Vector3D {
    Vector3D(x: vx, y: vy, z: vz).normalized()
}

/// Intersection of a line segment and a plane. Returns the point if the
/// segment crosses the plane, else nil.
public func intersectionOfLineSegAndPlane(
    _ plane: PlaneEquation,
    _ v1: Point3D,
    _ v2: Point3D
) -> Point3D? {
    let n = plane.normal
    let planeConst = plane.constant

    let r1 = -planeConst + (n.x * v1.x) + (n.y * v1.y) + (n.z * v1.z)
    let r2 = -planeConst + (n.x * v2.x) + (n.y * v2.y) + (n.z * v2.z)
    let a = r1 < 0
    let b = r2 < 0
    if a == b { return nil } // both on the same side: no crossing

    let vBA = Vector3D(x: v2.x - v1.x, y: v2.y - v1.y, z: v2.z - v1.z)
    let dot = (n.x * vBA.x) + (n.y * vBA.y) + (n.z * vBA.z)
    guard dot != 0 else { return nil } // parallel

    var lam = planeConst
    lam -= (n.x * v1.x) + (n.y * v1.y) + (n.z * v1.z)
    lam /= dot
    return Point3D(x: v1.x + lam * vBA.x, y: v1.y + lam * vBA.y, z: v1.z + lam * vBA.z)
}

/// Y coordinate where the vertical line at (x, z) meets the plane.
/// Caller must ensure the plane isn't vertical (normal.y != 0).
public func intersectionOfYAndPlane(x: Float, z: Float, plane: PlaneEquation) -> Float {
    (plane.constant - ((plane.normal.x * x) + (plane.normal.z * z))) / plane.normal.y
}
