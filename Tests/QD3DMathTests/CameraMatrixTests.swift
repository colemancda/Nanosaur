import Testing
import Foundation

@testable import QD3DMath

private func approx(_ a: Float, _ b: Float, _ tol: Float = 1e-4) -> Bool { abs(a - b) < tol }

@Test func glArrayIsRowMajorFlatten() {
    let m = Matrix4x4.translate(3, 4, 5)
    let a = m.glArray
    #expect(a.count == 16)
    // Row-major flatten -> GL column-major puts translation in the last column
    // (indices 12,13,14), which is what glLoadMatrixf expects.
    #expect(approx(a[12], 3) && approx(a[13], 4) && approx(a[14], 5) && approx(a[15], 1))
}

@Test func perspectiveHasExpectedShape() {
    let m = glPerspective(fovYDegrees: 90, aspect: 1, near: 1, far: 101)
    // tan(45°)=1 -> f=1, so m[0]=m[5]=1.
    #expect(approx(m[0], 1) && approx(m[5], 1))
    #expect(approx(m[11], -1))
    #expect(approx(m[10], (101 + 1) / (1 - 101)))
    #expect(approx(m[14], (2 * 101 * 1) / (1 - 101)))
    // Aspect widens x: doubling aspect halves m[0].
    let wide = glPerspective(fovYDegrees: 90, aspect: 2, near: 1, far: 101)
    #expect(approx(wide[0], 0.5))
}

@Test func lookAtDownNegativeZIsAxisAligned() {
    // Eye at origin looking toward -Z with +Y up: the rotation part is identity
    // (view space already matches world), translation is zero.
    let m = glLookAt(eye: Point3D(x: 0, y: 0, z: 0),
                     center: Point3D(x: 0, y: 0, z: -1),
                     up: Vector3D(x: 0, y: 1, z: 0))
    // s=+X, u=+Y, -f=+Z -> identity 3x3.
    #expect(approx(m[0], 1) && approx(m[5], 1) && approx(m[10], 1))
    #expect(approx(m[12], 0) && approx(m[13], 0) && approx(m[14], 0) && approx(m[15], 1))
}

@Test func lookAtTranslatesEyeToOrigin() {
    // From (0,0,10) looking at origin: a world point at the eye maps to view-
    // space origin. Verify the translation column encodes -eye in view space.
    let m = glLookAt(eye: Point3D(x: 0, y: 0, z: 10),
                     center: Point3D(x: 0, y: 0, z: 0),
                     up: Vector3D(x: 0, y: 1, z: 0))
    // f=-Z, so dot(f,eye) = -10 -> m[14] = -10 (eye ends up 10 in front).
    #expect(approx(m[14], -10))
}
