// SkeletonFile.swift - Decodes a parsed classic-Mac resource fork (see
// Sources/ResourceFile) into a structured skeleton + animation model,
// replacing the Resource Manager reads in ReadDataFromSkeletonFile()
// (src/System/File.c).
//
// A .skeleton.rsrc file stores these resources (all big-endian, per
// src/Headers/structformats.h):
//   'Hedr' 1000            SkeletonFile_Header_Type ">4h":
//                          version, numAnims, numJoints, num3DMFLimbs
//   'Bone' 1000+j          File_BoneDefinitionType ">l32c3fHH8L":
//                          parentBone, name[32], coord, numPoints,
//                          numNormals, reserved[8]
//   'BonP' 1000+j          UInt16[numPoints]  - point indices for bone j
//   'BonN' 1000+j          UInt16[numNormals] - normal indices for bone j
//   'RelP' 1000            TQ3Point3D[] ">3f"  - bone-relative point offsets
//   'AnHd' 1000+i          SkeletonFile_AnimHeader_Type ">B32cxh":
//                          Pascal name(1+32), pad, numAnimEvents
//   'Evnt' 1000+i          AnimEventType[numAnimEvents] ">hbb": time,type,value
//   'NumK' 1000+i          Int8[numJoints] - keyframe count per joint, anim i
//   'KeyF' 1000+(i*100)+j  JointKeyframeType[numKeyframes] ">2l9f":
//                          tick, accelerationMode, coord, rotation, scale
#if canImport(BinaryParsing)
import BinaryParsing
#endif
import ResourceFile

public enum SkeletonFileError: Error, Sendable, Equatable {
    case missingResource(type: UInt32, id: Int16)
}

public struct SkeletonPoint3D: Sendable, Equatable {
    public var x: Float
    public var y: Float
    public var z: Float
}

public struct SkeletonBone: Sendable, Equatable {
    public var parentBone: Int32       // index of parent bone, or -1 for root
    public var name: String
    public var coord: SkeletonPoint3D  // absolute coord (not relative to parent)
    public var pointIndices: [UInt16]  // decomposed-mesh points this bone owns
    public var normalIndices: [UInt16] // decomposed-mesh normals this bone owns
}

public struct SkeletonAnimEvent: Sendable, Equatable {
    public var time: Int16
    public var type: UInt8
    public var value: UInt8
}

public struct SkeletonKeyframe: Sendable, Equatable {
    public var tick: Int32
    public var accelerationMode: Int32
    public var coord: SkeletonPoint3D    // joint coord relative to its parent
    public var rotation: SkeletonPoint3D
    public var scale: SkeletonPoint3D
}

public struct SkeletonAnim: Sendable, Equatable {
    public var name: String
    public var events: [SkeletonAnimEvent]
    /// `jointKeyframes[joint]` is that joint's keyframe track for this anim.
    public var jointKeyframes: [[SkeletonKeyframe]]
}

/// A fully decoded skeleton file: reference-pose bones plus every animation's
/// keyframe tracks. The reference geometry itself lives in the companion 3DMF
/// model; `pointIndices`/`normalIndices` and `relativePointOffsets` refer into
/// that decomposed mesh.
public struct SkeletonFile: Sendable, Equatable {
    public var version: Int16
    public var num3DMFLimbs: Int
    public var bones: [SkeletonBone]
    public var relativePointOffsets: [SkeletonPoint3D]
    public var anims: [SkeletonAnim]

    public var numJoints: Int { bones.count }
    public var numAnims: Int { anims.count }
}

// OSType resource tags.
private let kHedr: UInt32 = 0x4865_6472
private let kBone: UInt32 = 0x426F_6E65
private let kBonP: UInt32 = 0x426F_6E50
private let kBonN: UInt32 = 0x426F_6E4E
private let kRelP: UInt32 = 0x5265_6C50
private let kAnHd: UInt32 = 0x416E_4864
private let kEvnt: UInt32 = 0x4576_6E74
private let kNumK: UInt32 = 0x4E75_6D4B
private let kKeyF: UInt32 = 0x4B65_7946

// swift-binary-parsing has no float parser: floats are stored big-endian, so
// read the raw UInt32 and reinterpret its bits.
private func parseFloatBE(_ input: inout ParserSpan) throws(ThrownParsingError) -> Float {
    Float(bitPattern: try UInt32(parsingBigEndian: &input))
}

private func parsePoint3D(_ input: inout ParserSpan) throws(ThrownParsingError) -> SkeletonPoint3D {
    let x = try parseFloatBE(&input)
    let y = try parseFloatBE(&input)
    let z = try parseFloatBE(&input)
    return SkeletonPoint3D(x: x, y: y, z: z)
}

// Reads a fixed-width byte field as a NUL-terminated C string.
private func parseFixedCString(_ input: inout ParserSpan, count: Int) throws(ThrownParsingError) -> String {
    let bytes = try [UInt8](parsing: &input, byteCount: count)
    let trimmed = bytes.prefix { $0 != 0 }
    return String(decoding: trimmed, as: UTF8.self)
}

extension SkeletonFile {
    /// Decodes the skeleton from an already-parsed resource fork.
    public init(resourceFile: ResourceFile) throws {
        func require(_ type: UInt32, _ id: Int16) throws -> [UInt8] {
            guard let data = resourceFile.resource(type: type, id: id) else {
                throw SkeletonFileError.missingResource(type: type, id: id)
            }
            return data
        }

        // 'Hedr' - counts.
        var version: Int16 = 0
        var numAnims = 0
        var numJoints = 0
        var num3DMFLimbs = 0
        try require(kHedr, 1000).withParserSpan { span in
            version = try Int16(parsingBigEndian: &span)
            numAnims = try Int(Int16(parsingBigEndian: &span))
            numJoints = try Int(Int16(parsingBigEndian: &span))
            num3DMFLimbs = try Int(Int16(parsingBigEndian: &span))
        }

        // 'Bone' + 'BonP' + 'BonN' - one bone definition per joint.
        var bones: [SkeletonBone] = []
        bones.reserveCapacity(numJoints)
        for j in 0..<numJoints {
            var parentBone: Int32 = 0
            var name = ""
            var coord = SkeletonPoint3D(x: 0, y: 0, z: 0)
            var numPoints = 0
            var numNormals = 0
            try require(kBone, Int16(1000 + j)).withParserSpan { span in
                parentBone = try Int32(parsingBigEndian: &span)
                name = try parseFixedCString(&span, count: 32)
                coord = try parsePoint3D(&span)
                numPoints = try Int(UInt16(parsingBigEndian: &span))
                numNormals = try Int(UInt16(parsingBigEndian: &span))
                // reserved[8] UInt32 - skip.
            }

            var pointIndices: [UInt16] = []
            pointIndices.reserveCapacity(numPoints)
            try require(kBonP, Int16(1000 + j)).withParserSpan { span in
                for _ in 0..<numPoints {
                    pointIndices.append(try UInt16(parsingBigEndian: &span))
                }
            }

            var normalIndices: [UInt16] = []
            normalIndices.reserveCapacity(numNormals)
            try require(kBonN, Int16(1000 + j)).withParserSpan { span in
                for _ in 0..<numNormals {
                    normalIndices.append(try UInt16(parsingBigEndian: &span))
                }
            }

            bones.append(SkeletonBone(
                parentBone: parentBone,
                name: name,
                coord: coord,
                pointIndices: pointIndices,
                normalIndices: normalIndices))
        }

        // 'RelP' - bone-relative point offsets (one TQ3Point3D each).
        var relativePointOffsets: [SkeletonPoint3D] = []
        let relPData = try require(kRelP, 1000)
        let numRelPoints = relPData.count / 12 // sizeof(TQ3Point3D)
        relativePointOffsets.reserveCapacity(numRelPoints)
        try relPData.withParserSpan { span in
            for _ in 0..<numRelPoints {
                relativePointOffsets.append(try parsePoint3D(&span))
            }
        }

        // Per-anim headers, events, and keyframe counts.
        var animNames: [String] = []
        var animEvents: [[SkeletonAnimEvent]] = []
        // numKeyframes[anim][joint]
        var numKeyframes: [[Int]] = []
        for i in 0..<numAnims {
            var name = ""
            var numEvents = 0
            try require(kAnHd, Int16(1000 + i)).withParserSpan { span in
                // Pascal string: 1 length byte + up to 32 chars.
                let length = try Int(UInt8(parsing: &span))
                let chars = try [UInt8](parsing: &span, byteCount: 32)
                name = String(decoding: chars.prefix(length), as: UTF8.self)
                _ = try UInt8(parsing: &span) // pad byte ('x' in the format)
                numEvents = try Int(Int16(parsingBigEndian: &span))
            }
            animNames.append(name)

            var events: [SkeletonAnimEvent] = []
            events.reserveCapacity(numEvents)
            try require(kEvnt, Int16(1000 + i)).withParserSpan { span in
                for _ in 0..<numEvents {
                    let time = try Int16(parsingBigEndian: &span)
                    let type = try UInt8(parsing: &span)
                    let value = try UInt8(parsing: &span)
                    events.append(SkeletonAnimEvent(time: time, type: type, value: value))
                }
            }
            animEvents.append(events)

            var counts: [Int] = []
            counts.reserveCapacity(numJoints)
            try require(kNumK, Int16(1000 + i)).withParserSpan { span in
                for _ in 0..<numJoints {
                    counts.append(try Int(Int8(bitPattern: UInt8(parsing: &span))))
                }
            }
            numKeyframes.append(counts)
        }

        // 'KeyF' - each joint's keyframe track for each anim.
        var anims: [SkeletonAnim] = []
        anims.reserveCapacity(numAnims)
        for i in 0..<numAnims {
            var jointTracks: [[SkeletonKeyframe]] = []
            jointTracks.reserveCapacity(numJoints)
            for j in 0..<numJoints {
                let count = numKeyframes[i][j]
                var track: [SkeletonKeyframe] = []
                track.reserveCapacity(count)
                try require(kKeyF, Int16(1000 + (i * 100) + j)).withParserSpan { span in
                    for _ in 0..<count {
                        let tick = try Int32(parsingBigEndian: &span)
                        let accel = try Int32(parsingBigEndian: &span)
                        let coord = try parsePoint3D(&span)
                        let rotation = try parsePoint3D(&span)
                        let scale = try parsePoint3D(&span)
                        track.append(SkeletonKeyframe(
                            tick: tick, accelerationMode: accel,
                            coord: coord, rotation: rotation, scale: scale))
                    }
                }
                jointTracks.append(track)
            }
            anims.append(SkeletonAnim(
                name: animNames[i], events: animEvents[i], jointKeyframes: jointTracks))
        }

        self.version = version
        self.num3DMFLimbs = num3DMFLimbs
        self.bones = bones
        self.relativePointOffsets = relativePointOffsets
        self.anims = anims
    }

    /// Convenience: parse a resource fork and decode it in one step.
    public init(parsingResourceFork data: some Sequence<UInt8>) throws {
        try self.init(resourceFile: try ResourceFile(parsing: Array(data)))
    }
}
