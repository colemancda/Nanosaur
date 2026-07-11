// Skeleton.swift - Skeletal animation + skinning, ported from src/Skeleton
// (Bones.c, SkeletonAnim.c, SkeletonJoints.c). A skeleton "decomposes" its
// reference .3dmf into a deduplicated point/normal list (matching the ordering
// the .skeleton file was authored with - verified: our dedup reproduces the
// exact decomposed-point count the file expects), then each frame:
//   1. advance the animation clock, interpolating per-joint keyframes,
//   2. build each joint's local transform matrix,
//   3. walk the bone hierarchy accumulating matrices and deforming every
//      point/normal into world space (UpdateSkinnedGeometry).
// The deformed points/normals are written back into per-mesh buffers the
// renderer draws with an identity model transform (they're already in world
// space).
import QD3DFile
import SkeletonFile
import QD3DMath

// Anim event types (skeletonanim.h).
private enum AnimEvent {
    static let stop: UInt8 = 0
    static let loop: UInt8 = 1
    static let setMarker: UInt8 = 4
}

private func closePoint(_ a: Point3D, _ b: Point3D) -> Bool {
    abs(a.x - b.x) < 0.001 && abs(a.y - b.y) < 0.001 && abs(a.z - b.z) < 0.001
}
private func closeVector(_ a: Vector3D, _ b: Vector3D) -> Bool {
    abs(a.x - b.x) < 0.02 && abs(a.y - b.y) < 0.02 && abs(a.z - b.z) < 0.02
}

/// One decomposed vertex: its bone-relative offset plus every (mesh, vertex,
/// normal) location in the reference meshes that shares this position.
struct DecomposedPoint {
    var boneRelPoint: Point3D
    var refs: [(mesh: Int, vertex: Int, normalIndex: Int)]
}

/// A joint's interpolated pose for the current frame.
struct JointPose {
    var coord = Point3D()
    var rotation = Vector3D()
    var scale = Vector3D(x: 1, y: 1, z: 1)
}

/// Immutable skeleton data shared by every instance: decomposed geometry, bone
/// hierarchy, and animations.
public final class SkeletonModel {
    struct Bone {
        var parent: Int
        var pointIndices: [Int]
        var normalIndices: [Int]
    }
    struct Anim {
        var events: [(time: Float, type: UInt8, value: UInt8)]
        var jointKeyframes: [[SkeletonKeyframe]] // [joint][keyframe]
        var maxTime: Float
    }

    let numJoints: Int
    var decomposedPoints: [DecomposedPoint]
    var decomposedNormals: [Vector3D]
    var bones: [Bone]
    var childIndices: [[Int]]
    var anims: [Anim]
    /// Reference vertex/normal counts per mesh, to size instance buffers.
    let meshVertexCounts: [Int]

    public init(meshFile: MetaFile3D, skeletonFile: SkeletonFile) {
        numJoints = skeletonFile.numJoints
        meshVertexCounts = meshFile.meshes.map { $0.points.count }

        // Decompose the reference meshes (dedup positions @0.001, normals
        // @0.02), in mesh/vertex order, to reproduce the file's point ordering.
        var points: [DecomposedPoint] = []
        var realPoints: [Point3D] = []
        var normals: [Vector3D] = []

        for (meshIdx, mesh) in meshFile.meshes.enumerated() {
            for (vertIdx, qp) in mesh.points.enumerated() {
                let p = Point3D(x: qp.x, y: qp.y, z: qp.z)

                var pointIdx = -1
                for (k, rp) in realPoints.enumerated() where closePoint(p, rp) { pointIdx = k; break }
                if pointIdx < 0 {
                    pointIdx = points.count
                    realPoints.append(p)
                    points.append(DecomposedPoint(boneRelPoint: Point3D(), refs: []))
                }

                // Normal for this vertex (dedup into the shared normal list).
                let nv: Vector3D
                if let ns = mesh.vertexNormals, vertIdx < ns.count {
                    nv = Vector3D(x: ns[vertIdx].x, y: ns[vertIdx].y, z: ns[vertIdx].z).normalized()
                } else {
                    nv = Vector3D(x: 0, y: 1, z: 0)
                }
                var normalIdx = -1
                for (k, dn) in normals.enumerated() where closeVector(nv, dn) { normalIdx = k; break }
                if normalIdx < 0 { normalIdx = normals.count; normals.append(nv) }

                points[pointIdx].refs.append((mesh: meshIdx, vertex: vertIdx, normalIndex: normalIdx))
            }
        }

        // Attach the bone-relative offsets from the .skeleton file (index i
        // pairs with decomposed point i - the counts match by construction).
        for i in 0..<min(points.count, skeletonFile.relativePointOffsets.count) {
            let o = skeletonFile.relativePointOffsets[i]
            points[i].boneRelPoint = Point3D(x: o.x, y: o.y, z: o.z)
        }
        decomposedPoints = points
        decomposedNormals = normals

        bones = skeletonFile.bones.map {
            Bone(parent: Int($0.parentBone),
                 pointIndices: $0.pointIndices.map(Int.init),
                 normalIndices: $0.normalIndices.map(Int.init))
        }

        // Forward child links (PrimeBoneData).
        childIndices = Array(repeating: [], count: bones.count)
        for (i, bone) in bones.enumerated() where bone.parent >= 0 {
            childIndices[bone.parent].append(i)
        }

        anims = skeletonFile.anims.map { anim in
            let maxTime = anim.jointKeyframes.compactMap { $0.last?.tick }.max().map(Float.init) ?? 0
            return Anim(
                events: anim.events.map { (time: Float($0.time), type: $0.type, value: $0.value) },
                jointKeyframes: anim.jointKeyframes,
                maxTime: maxTime)
        }
    }

    public var animCount: Int { anims.count }
}

/// A playing instance of a skeleton: owns the animation clock and the deformed
/// per-mesh geometry the renderer consumes.
public final class SkeletonInstance {
    public let model: SkeletonModel
    public private(set) var animNum: Int

    private var currentTime: Float = 0
    public var animSpeed: Float = 1
    private var animEventIndex = 0
    private var loopBackTime: Float = 0
    public private(set) var animHasStopped = false

    private var jointPose: [JointPose]
    private var jointTransform: [Matrix4x4]
    private var transformedNormals: [Vector3D]
    private var gMatrix = Matrix4x4.identity

    /// Deformed world-space geometry per reference mesh (3 floats/vertex).
    public private(set) var deformedPoints: [[Float]]
    public private(set) var deformedNormals: [[Float]]

    public init(model: SkeletonModel, animNum: Int = 0) {
        self.model = model
        self.animNum = min(max(0, animNum), max(0, model.animCount - 1))
        jointPose = Array(repeating: JointPose(), count: model.numJoints)
        jointTransform = Array(repeating: .identity, count: model.numJoints)
        transformedNormals = Array(repeating: Vector3D(), count: model.decomposedNormals.count)
        deformedPoints = model.meshVertexCounts.map { [Float](repeating: 0, count: $0 * 3) }
        deformedNormals = model.meshVertexCounts.map { [Float](repeating: 0, count: $0 * 3) }
    }

    public func setAnim(_ n: Int) {
        guard n >= 0, n < model.animCount else { return }
        animNum = n
        currentTime = 0
        animEventIndex = 0
        loopBackTime = 0
        animHasStopped = false
        animSpeed = 1
    }

    /// Advance one frame: `dt` seconds elapsed; `baseTransform` is the object's
    /// world transform the deformed geometry is placed into.
    public func update(dt: Float, baseTransform: Matrix4x4 = .identity) {
        advanceTime(dt)
        getModelCurrentPosition()
        gMatrix = baseTransform
        if !model.bones.isEmpty {
            deform(joint: 0)
        }
    }

    // MARK: Animation clock (UpdateSkeletonAnimation, forward playback)

    private func advanceTime(_ dt: Float) {
        guard animNum < model.anims.count else { return }
        let anim = model.anims[animNum]
        currentTime += 30 * dt * animSpeed

        var loopCount = 0
        while animEventIndex < anim.events.count, currentTime >= anim.events[animEventIndex].time {
            let e = anim.events[animEventIndex]
            switch e.type {
            case AnimEvent.stop:
                animHasStopped = true
                animEventIndex += 1
            case AnimEvent.setMarker:
                loopBackTime = e.time
                animEventIndex += 1
            case AnimEvent.loop:
                loopCount += 1
                if loopBackTime != 0 {
                    currentTime -= e.time
                    currentTime += loopBackTime
                    animEventIndex = firstEventAtOrAfter(currentTime, anim)
                } else if currentTime != 0 {
                    currentTime -= e.time
                    animEventIndex = 0
                } else {
                    animHasStopped = true
                    animEventIndex += 1
                }
            default:
                animEventIndex += 1
            }
            if loopCount > 1 { break }
        }

        // Safety net: if an anim has no loop event, wrap at maxTime so it repeats.
        if anim.events.isEmpty, anim.maxTime > 0, currentTime > anim.maxTime {
            currentTime = currentTime.truncatingRemainder(dividingBy: anim.maxTime)
        }
    }

    private func firstEventAtOrAfter(_ time: Float, _ anim: SkeletonModel.Anim) -> Int {
        for (i, e) in anim.events.enumerated() where e.time >= time { return i }
        return anim.events.count
    }

    // MARK: Pose (GetModelCurrentPosition + UpdateJointTransforms)

    private func getModelCurrentPosition() {
        guard animNum < model.anims.count else { return }
        let anim = model.anims[animNum]
        for joint in 0..<model.numJoints {
            guard joint < anim.jointKeyframes.count else { return }
            let frames = anim.jointKeyframes[joint]
            if frames.isEmpty { return }

            var pose = JointPose()
            var set = false
            for (k, kf) in frames.enumerated() {
                let tick = Float(kf.tick)
                if tick == currentTime {
                    pose = makePose(from: kf); set = true; break
                } else if tick > currentTime {
                    if k == 0 { pose = makePose(from: kf) }
                    else { pose = interpolate(frames[k - 1], kf, at: currentTime) }
                    set = true; break
                }
            }
            if !set { pose = makePose(from: frames[frames.count - 1]) } // past the end

            jointPose[joint] = pose
            updateJointTransform(joint)
        }
    }

    private func makePose(from kf: SkeletonKeyframe) -> JointPose {
        JointPose(coord: Point3D(x: kf.coord.x, y: kf.coord.y, z: kf.coord.z),
                  rotation: Vector3D(x: kf.rotation.x, y: kf.rotation.y, z: kf.rotation.z),
                  scale: Vector3D(x: kf.scale.x, y: kf.scale.y, z: kf.scale.z))
    }

    private func interpolate(_ a: SkeletonKeyframe, _ b: SkeletonKeyframe, at time: Float) -> JointPose {
        let t1 = Float(a.tick), t2 = Float(b.tick)
        let span = t2 - t1
        let k2 = span != 0 ? (time - t1) / span : 0
        let k1 = 1 - k2
        func lerp(_ x: Float, _ y: Float) -> Float { x * k1 + y * k2 }
        var p = JointPose()
        p.coord = Point3D(x: lerp(a.coord.x, b.coord.x), y: lerp(a.coord.y, b.coord.y), z: lerp(a.coord.z, b.coord.z))
        p.rotation = Vector3D(x: lerp(a.rotation.x, b.rotation.x), y: lerp(a.rotation.y, b.rotation.y), z: lerp(a.rotation.z, b.rotation.z))
        if a.scale.x != 1 || b.scale.x != 1 {
            p.scale = Vector3D(x: lerp(a.scale.x, b.scale.x), y: lerp(a.scale.y, b.scale.y), z: lerp(a.scale.z, b.scale.z))
        }
        return p
    }

    private func updateJointTransform(_ joint: Int) {
        let pose = jointPose[joint]
        var m = Matrix4x4.rotationXYZ(pose.rotation.x, pose.rotation.y, pose.rotation.z)
        if pose.scale.x != 1 || pose.scale.y != 1 || pose.scale.z != 1 {
            var st = Matrix4x4.identity
            st.value[0][0] = pose.scale.x; st.value[1][1] = pose.scale.y; st.value[2][2] = pose.scale.z
            st.value[3][0] = pose.coord.x; st.value[3][1] = pose.coord.y; st.value[3][2] = pose.coord.z
            m = m.multiplied(by: st)
        } else {
            m.value[3][0] = pose.coord.x; m.value[3][1] = pose.coord.y; m.value[3][2] = pose.coord.z
        }
        jointTransform[joint] = m
    }

    // MARK: Skinning (UpdateSkinnedGeometry_Recurse)

    private func deform(joint: Int) {
        // Accumulate this joint's transform onto the running matrix.
        gMatrix = jointTransform[joint].multiplied(by: gMatrix)
        let bone = model.bones[joint]

        // Transform this bone's normals (3x3, no translation). Indices are
        // guarded in case a file's normal decomposition doesn't line up exactly.
        for ni in bone.normalIndices where ni < transformedNormals.count {
            transformedNormals[ni] = transformVector(model.decomposedNormals[ni], gMatrix)
        }
        for pi in bone.pointIndices where pi < model.decomposedPoints.count {
            for ref in model.decomposedPoints[pi].refs where ref.normalIndex < transformedNormals.count {
                let tn = transformedNormals[ref.normalIndex]
                let base = ref.vertex * 3
                guard base + 2 < deformedNormals[ref.mesh].count else { continue }
                deformedNormals[ref.mesh][base + 0] = tn.x
                deformedNormals[ref.mesh][base + 1] = tn.y
                deformedNormals[ref.mesh][base + 2] = tn.z
            }
        }

        // Transform this bone's points (full transform, into world space).
        for pi in bone.pointIndices where pi < model.decomposedPoints.count {
            let wp = model.decomposedPoints[pi].boneRelPoint.transformed(by: gMatrix)
            for ref in model.decomposedPoints[pi].refs {
                let base = ref.vertex * 3
                guard base + 2 < deformedPoints[ref.mesh].count else { continue }
                deformedPoints[ref.mesh][base + 0] = wp.x
                deformedPoints[ref.mesh][base + 1] = wp.y
                deformedPoints[ref.mesh][base + 2] = wp.z
            }
        }

        // Recurse into children, restoring the matrix for each sibling.
        let saved = gMatrix
        for child in model.childIndices[joint] {
            gMatrix = saved
            deform(joint: child)
        }
        gMatrix = saved
    }

    private func transformVector(_ v: Vector3D, _ m: Matrix4x4) -> Vector3D {
        Vector3D(
            x: v.x * m.value[0][0] + v.y * m.value[1][0] + v.z * m.value[2][0],
            y: v.x * m.value[0][1] + v.y * m.value[1][1] + v.z * m.value[2][1],
            z: v.x * m.value[0][2] + v.y * m.value[1][2] + v.z * m.value[2][2])
    }
}
