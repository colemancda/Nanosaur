import Testing

@testable import NanosaurEngine
import QD3DMath

private func approx(_ a: Float, _ b: Float, _ tol: Float = 1e-4) -> Bool { abs(a - b) < tol }

private func def(slot: Int, move: ((ObjNode) -> Void)? = nil) -> NewObjectDefinition {
    var d = NewObjectDefinition()
    d.slot = slot
    d.moveCall = move
    return d
}

@Test func objectsInsertInSlotOrder() {
    let mgr = ObjectManager()
    mgr.makeNewObject(def(slot: 100))
    mgr.makeNewObject(def(slot: 10))
    mgr.makeNewObject(def(slot: 50))
    mgr.makeNewObject(def(slot: 3000))
    mgr.makeNewObject(def(slot: 5)) // new head
    #expect(mgr.allObjects().map(\.slot) == [5, 10, 50, 100, 3000])
    // Back-links are consistent.
    let objs = mgr.allObjects()
    for i in 1..<objs.count {
        #expect(objs[i].prevNode === objs[i - 1])
    }
}

@Test func moveObjectsCallsEachMoveRoutine() {
    let mgr = ObjectManager()
    var counts: [Int: Int] = [:]
    for slot in [30, 10, 20] {
        var d = def(slot: slot) { node in counts[node.slot, default: 0] += 1 }
        _ = d
        mgr.makeNewObject(d)
    }
    mgr.moveObjects()
    mgr.moveObjects()
    #expect(counts == [10: 2, 20: 2, 30: 2])
}

@Test func noMoveStatusSkipsMoveRoutine() {
    let mgr = ObjectManager()
    var called = false
    var d = def(slot: 1) { _ in called = true }
    d.flags = StatusBit.noMove
    mgr.makeNewObject(d)
    mgr.moveObjects()
    #expect(!called)
}

@Test func moveRoutineCanDeleteObjectsSafely() {
    // A move routine deletes the *next* node; the walk must skip it and not
    // crash or revisit a dead node.
    let mgr = ObjectManager()
    var visited: [Int] = []
    let first = mgr.makeNewObject(def(slot: 1) { node in
        visited.append(node.slot)
        // delete the node after this one (slot 2)
        mgr.deleteObject(node.nextNode)
    })
    _ = first
    mgr.makeNewObject(def(slot: 2) { node in visited.append(node.slot) })
    mgr.makeNewObject(def(slot: 3) { node in visited.append(node.slot) })

    mgr.moveObjects()
    #expect(visited == [1, 3]) // slot 2 was deleted before it could run
    #expect(mgr.allObjects().map(\.slot) == [1, 3])
}

@Test func deleteHeadAndTailRelink() {
    let mgr = ObjectManager()
    for s in [1, 2, 3] { mgr.makeNewObject(def(slot: s)) }
    let objs = mgr.allObjects()
    mgr.deleteObject(objs[0]) // head
    #expect(mgr.allObjects().map(\.slot) == [2, 3])
    #expect(mgr.firstNode?.prevNode == nil)
    let remaining = mgr.allObjects()
    mgr.deleteObject(remaining.last) // tail
    #expect(mgr.allObjects().map(\.slot) == [2])
    #expect(mgr.firstNode?.nextNode == nil)
}

@Test func deleteMarksNodeInvalid() {
    let mgr = ObjectManager()
    let n = mgr.makeNewObject(def(slot: 1))
    mgr.deleteObject(n)
    #expect(n.cType == invalidNodeFlag)
}

@Test func transformTranslatesByCoord() {
    let mgr = ObjectManager()
    var d = def(slot: 1)
    d.coord = Point3D(x: 10, y: 20, z: -5)
    d.scale = 1
    let n = mgr.makeNewObject(d)
    mgr.updateObjectTransforms(n)
    // With identity rotation/scale, a point at the origin maps to the coord.
    let origin = Point3D().transformed(by: n.baseTransformMatrix)
    #expect(approx(origin.x, 10) && approx(origin.y, 20) && approx(origin.z, -5))
}

@Test func transformScalesThenTranslates() {
    let mgr = ObjectManager()
    var d = def(slot: 1)
    d.coord = Point3D(x: 100, y: 0, z: 0)
    d.scale = 2
    let n = mgr.makeNewObject(d)
    mgr.updateObjectTransforms(n)
    // A point at local (1,0,0) scales to (2,0,0) then translates to (102,0,0).
    let p = Point3D(x: 1, y: 0, z: 0).transformed(by: n.baseTransformMatrix)
    #expect(approx(p.x, 102) && approx(p.y, 0) && approx(p.z, 0))
}
