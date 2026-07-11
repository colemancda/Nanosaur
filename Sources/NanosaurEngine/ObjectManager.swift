// ObjectManager.swift - The ObjNode object system, ported from
// src/System/Objects.c. The whole engine runs off one Slot-ordered doubly
// linked list of ObjNode "game items" (dinosaurs, bullets, rocks, shadows,
// ...). Each frame MoveObjects() walks the list and calls every node's move
// routine; the list is drawn in Slot order. See docs/Nanosaur Game Engine
// Docs.md ("Game Objects").
//
// This is the pure-logic core (no rendering/skeleton/terrain yet - those land
// as the renderer and gameplay layers are ported). Mesh/skeleton attachment,
// collision boxes, and DrawObjects come later.
import QD3DMath

/// Object genres (objects.h). A SKELETON object is an animated character; a
/// DISPLAY_GROUP object is static geometry; an EVENT object carries no geometry
/// (timers, particle emitters).
public enum ObjectGenre: UInt8, Sendable, Equatable {
    case skeleton = 0
    case displayGroup = 1
    case event = 2
}

/// ObjNode.StatusBits (globals.h).
public enum StatusBit {
    public static let onGround: UInt32 = 1
    public static let isCarrying: UInt32 = 1 << 1
    public static let dontCull: UInt32 = 1 << 2
    public static let noCollision: UInt32 = 1 << 3
    public static let noMove: UInt32 = 1 << 4
    public static let anim: UInt32 = 1 << 5
    public static let hidden: UInt32 = 1 << 6
    public static let reflectionMap: UInt32 = 1 << 7
    public static let rotZYX: UInt32 = 1 << 8
    public static let rotXZY: UInt32 = 1 << 9
    public static let isCulled: UInt32 = 1 << 10
    public static let highFilter: UInt32 = 1 << 11
    public static let highFilter2: UInt32 = 1 << 12
    public static let nullShader: UInt32 = 1 << 13
    public static let alwaysCull: UInt32 = 1 << 14
    public static let blendInterpolate: UInt32 = 1 << 15
    public static let noTriCache: UInt32 = 1 << 16
    public static let keepBackfaces: UInt32 = 1 << 17
    public static let noZWrite: UInt32 = 1 << 18
}

/// Written into CType when a node is deleted, to catch use-after-free /
/// double-delete (objects.h INVALID_NODE_FLAG).
public let invalidNodeFlag: UInt32 = 0xDEAD_BEEF

/// The default object definition passed to `makeNewObject`
/// (NewObjectDefinitionType).
public struct NewObjectDefinition {
    public var genre: ObjectGenre = .displayGroup
    public var group: UInt8 = 0
    public var type: UInt8 = 0
    public var animNum: UInt8 = 0
    public var coord: Point3D = Point3D()
    public var flags: UInt32 = 0
    public var slot: Int = 0
    public var rot: Float = 0
    public var scale: Float = 1
    public var moveCall: ((ObjNode) -> Void)?

    public init() {}
}

/// A single game object: one node of the master linked list. Reference type -
/// nodes have identity and are referenced by shadow/platform/carried links and
/// captured by move routines.
public final class ObjNode {
    // Linked-list wiring. `next` owns the rest of the chain; `prev` is a back
    // link (weak to avoid a retain cycle - the manager + `next` chain own the
    // nodes).
    public var nextNode: ObjNode?
    public weak var prevNode: ObjNode?

    public var slot: Int = 0
    public var genre: ObjectGenre = .displayGroup
    public var type: UInt8 = 0
    public var group: UInt8 = 0
    public var moveCall: ((ObjNode) -> Void)?

    public var coord = Point3D()
    public var oldCoord = Point3D()
    public var delta = Vector3D()
    public var rot = Vector3D()
    public var rotDelta = Vector3D()
    public var scale = Vector3D(x: 1, y: 1, z: 1)

    public var speed: Float = 0
    public var accel: Float = 0
    public var terrainAccel = Vector2D()
    public var targetOff = Point2D()

    public var cType: UInt32 = 0 // collision type bits
    public var cBits: UInt32 = 0 // collision attribute bits
    public var kind: UInt8 = 0

    public var flag = [Int8](repeating: 0, count: 6)
    public var special = [Int](repeating: 0, count: 6)
    public var specialF = [Float](repeating: 0, count: 6)

    public var health: Float = 0
    public var damage: Float = 0

    public var statusBits: UInt32 = 0

    // Simple (single-box) collision offsets. Full collision boxes land with the
    // collision layer.
    public var numCollisionBoxes: Int = 0
    public var leftOff: Float = 0, rightOff: Float = 0
    public var frontOff: Float = 0, backOff: Float = 0
    public var topOff: Float = 0, bottomOff: Float = 0

    public var radius: Float = 4

    public var baseTransformMatrix = Matrix4x4.identity

    /// Index into the terrain item list this object came from, if any.
    public var terrainItemIndex: Int?

    public init() {}

    public func hasStatus(_ bit: UInt32) -> Bool { (statusBits & bit) != 0 }
}

/// Owns and processes the master ObjNode linked list.
public final class ObjectManager {
    /// Head of the Slot-ordered list (smallest Slot first).
    public private(set) var firstNode: ObjNode?

    /// The node MoveObjects is currently processing, and the node it will
    /// process next - exposed so move routines (and deleteObject) can reason
    /// about safe deletion mid-walk, matching gCurrentNode/gNextNode.
    public private(set) var currentNode: ObjNode?
    public private(set) var nextNode: ObjNode?
    public private(set) var mostRecentlyAddedNode: ObjNode?

    public init() {}

    /// MakeNewObject: create a node and insert it into the list in Slot order
    /// (smallest to largest).
    @discardableResult
    public func makeNewObject(_ def: NewObjectDefinition) -> ObjNode {
        let node = ObjNode()
        node.slot = def.slot
        node.type = def.type
        node.group = def.group
        node.moveCall = def.moveCall
        node.genre = def.genre
        node.coord = def.coord
        node.oldCoord = def.coord
        node.statusBits = def.flags
        node.rot = Vector3D(x: 0, y: def.rot, z: 0)
        node.scale = Vector3D(x: def.scale, y: def.scale, z: def.scale)
        node.radius = 4

        // Scale must never be exactly zero (matrix would be singular).
        if node.scale.x == 0 { node.scale.x = 0.0001 }
        if node.scale.y == 0 { node.scale.y = 0.0001 }
        if node.scale.z == 0 { node.scale.z = 0.0001 }

        insertBySlot(node)
        mostRecentlyAddedNode = node
        return node
    }

    private func insertBySlot(_ node: ObjNode) {
        guard let first = firstNode else { // only entry
            firstNode = node
            node.prevNode = nil
            node.nextNode = nil
            return
        }

        if node.slot < first.slot { // insert as first node
            node.prevNode = nil
            node.nextNode = first
            first.prevNode = node
            firstNode = node
            return
        }

        var rePtr = first
        var scan = first.nextNode
        while let s = scan {
            if node.slot < s.slot { // insert in the middle
                node.nextNode = s
                node.prevNode = rePtr
                rePtr.nextNode = node
                s.prevNode = node
                return
            }
            rePtr = s
            scan = s.nextNode
        }

        // Tag to end.
        node.nextNode = nil
        node.prevNode = rePtr
        rePtr.nextNode = node
    }

    /// MoveObjects: walk the list, update each object. Captures the next node
    /// before each move so a move routine can delete the current (or next)
    /// node safely.
    public func moveObjects() {
        guard firstNode != nil else { return }

        var thisNode = firstNode
        while let node = thisNode {
            nextNode = node.nextNode
            currentNode = node

            node.oldCoord = node.coord // KeepOldCollisionBoxes analogue

            if !node.hasStatus(StatusBit.noMove), let move = node.moveCall {
                move(node)
            }

            thisNode = nextNode
        }
        currentNode = nil
        nextNode = nil
    }

    /// DeleteObject: unlink a node from the list and mark it dead. If it was
    /// slated to be processed next by moveObjects, advance the walk past it.
    public func deleteObject(_ node: ObjNode?) {
        guard let node else { return }
        precondition(node.cType != invalidNodeFlag, "double-delete of an ObjNode")

        if node === nextNode { // don't let moveObjects step onto a dead node
            nextNode = node.nextNode
        }

        let prev = node.prevNode
        let next = node.nextNode
        if prev == nil { // first node
            firstNode = next
            next?.prevNode = nil
        } else {
            prev?.nextNode = next
            next?.prevNode = prev
        }

        node.nextNode = nil
        node.prevNode = nil
        node.cType = invalidNodeFlag // mark dead
    }

    /// UpdateObjectTransforms: rebuild a node's base transform from its scale,
    /// rotation (order per its status bits), and translation.
    public func updateObjectTransforms(_ node: ObjNode) {
        guard node.cType != invalidNodeFlag else { return }

        var m = Matrix4x4.identity

        if node.scale.x != 1 || node.scale.y != 1 || node.scale.z != 1 {
            m = m.multiplied(by: .scale(node.scale.x, node.scale.y, node.scale.z))
        }

        if node.hasStatus(StatusBit.rotZYX) {
            m = m.multiplied(by: .rotationZ(node.rot.z))
            m = m.multiplied(by: .rotationY(node.rot.y))
            m = m.multiplied(by: .rotationX(node.rot.x))
        } else if node.hasStatus(StatusBit.rotXZY) {
            m = m.multiplied(by: .rotationX(node.rot.x))
            m = m.multiplied(by: .rotationZ(node.rot.z))
            m = m.multiplied(by: .rotationY(node.rot.y))
        } else {
            m = m.multiplied(by: .rotationXYZ(node.rot.x, node.rot.y, node.rot.z))
        }

        m = m.multiplied(by: .translate(node.coord.x, node.coord.y, node.coord.z))
        node.baseTransformMatrix = m
    }

    /// Slot-ordered snapshot of the live list (mainly for tests/inspection).
    public func allObjects() -> [ObjNode] {
        var result: [ObjNode] = []
        var n = firstNode
        while let node = n {
            result.append(node)
            n = node.nextNode
        }
        return result
    }
}
