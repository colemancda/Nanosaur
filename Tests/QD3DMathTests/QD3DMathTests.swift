import Testing
import Foundation

@testable import QD3DMath

private func approx(_ a: Float, _ b: Float, _ tol: Float = 1e-4) -> Bool { abs(a - b) < tol }

@Test func maskAngleWraps() {
    #expect(approx(maskAngle(0), 0))
    #expect(approx(maskAngle(pi2), 0))
    #expect(approx(maskAngle(pi2 + 1), 1))
    #expect(approx(maskAngle(-1), pi2 - 1))
    for a: Float in stride(from: -20, through: 20, by: 0.5) {
        let m = maskAngle(a)
        #expect(m >= 0 && m < pi2 + 1e-4)
    }
}

@Test func vectorOps() {
    let v = Vector3D(x: 3, y: 0, z: 4)
    #expect(approx(v.length, 5))
    let n = v.normalized()
    #expect(approx(n.length, 1))
    #expect(approx(Vector3D(x: 1, y: 0, z: 0).dot(Vector3D(x: 0, y: 1, z: 0)), 0))
    // Right-handed cross product: x cross y = z.
    let c = Vector3D(x: 1, y: 0, z: 0).cross(Vector3D(x: 0, y: 1, z: 0))
    #expect(approx(c.x, 0) && approx(c.y, 0) && approx(c.z, 1))
}

@Test func faceNormalOfFlatTriangle() {
    // Triangle in the y=0 plane -> normal is ±Y.
    let n = calcFaceNormal(
        Point3D(x: 0, y: 0, z: 0),
        Point3D(x: 1, y: 0, z: 0),
        Point3D(x: 0, y: 0, z: 1))
    #expect(approx(abs(n.y), 1))
    #expect(approx(n.x, 0) && approx(n.z, 0))
}

@Test func identityMatrixTransformIsNoOp() {
    let p = Point3D(x: 2, y: -3, z: 7)
    let t = p.transformed(by: .identity)
    #expect(approx(t.x, p.x) && approx(t.y, p.y) && approx(t.z, p.z))
}

@Test func translationMatrixTransforms() {
    var m = Matrix4x4.identity
    m.value[3][0] = 10 // translate x
    m.value[3][2] = -5 // translate z
    let t = Point3D(x: 1, y: 1, z: 1).transformed(by: m)
    #expect(approx(t.x, 11) && approx(t.y, 1) && approx(t.z, -4))
}

@Test func matrixMultiplyIdentity() {
    let r = quickRotationMatrixXYZ(rx: 0.3, ry: -0.7, rz: 1.1)
    let product = r.multiplied(by: .identity)
    for i in 0..<4 {
        for j in 0..<4 {
            #expect(approx(product.value[i][j], r.value[i][j]))
        }
    }
}

@Test func lineSegmentPlaneIntersection() {
    // Plane y = 0 (normal +Y, constant 0). Segment from y=1 to y=-1 crosses at y=0.
    let plane = PlaneEquation(normal: Vector3D(x: 0, y: 1, z: 0), constant: 0)
    let hit = intersectionOfLineSegAndPlane(plane, Point3D(x: 3, y: 1, z: 4), Point3D(x: 3, y: -1, z: 4))
    #expect(hit != nil)
    #expect(approx(hit!.y, 0))
    #expect(approx(hit!.x, 3) && approx(hit!.z, 4))

    // Segment entirely above the plane: no intersection.
    #expect(intersectionOfLineSegAndPlane(plane, Point3D(x: 0, y: 1, z: 0), Point3D(x: 0, y: 2, z: 0)) == nil)
}

@Test func quickDistanceIsSymmetric() {
    #expect(approx(calcQuickDistance(0, 0, 3, 4), calcQuickDistance(3, 4, 0, 0)))
}

@Test func planeFromFlatTriangleGivesVerticalNormalAndYSampling() {
    // Triangle at height y=5 in the XZ plane -> plane samples to y=5 everywhere.
    let plane = calcPlaneEquationOfTriangle(
        Point3D(x: 0, y: 5, z: 0),
        Point3D(x: 0, y: 5, z: 1),
        Point3D(x: 1, y: 5, z: 0))
    #expect(approx(abs(plane.normal.y), 1))
    #expect(approx(intersectionOfYAndPlane(x: 12, z: -8, plane: plane), 5))
}
