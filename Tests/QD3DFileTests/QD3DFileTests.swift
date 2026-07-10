import Foundation
import Testing

@testable import QD3DFile

private func modelURLs() -> [URL] {
    let dataDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // QD3DFileTests.swift -> QD3DFileTests/
        .deletingLastPathComponent() // -> Tests/
        .deletingLastPathComponent() // -> repo root
        .appendingPathComponent("Data")
    let fm = FileManager.default
    return ["Models", "Skeletons"].flatMap { subdir -> [URL] in
        let dir = dataDir.appendingPathComponent(subdir)
        guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "3dmf" }
    }.sorted { $0.lastPathComponent < $1.lastPathComponent }
}

@Test func allModelsParse() throws {
    let urls = modelURLs()
    #expect(!urls.isEmpty)
    for url in urls {
        let file = try MetaFile3D(parsing3DMF: try Data(contentsOf: url))
        #expect(!file.topLevelGroups.isEmpty, "\(url.lastPathComponent) has no top-level groups")
        #expect(!file.meshes.isEmpty, "\(url.lastPathComponent) has no meshes")

        for mesh in file.meshes {
            #expect(!mesh.points.isEmpty)
            #expect(!mesh.triangles.isEmpty)
            // Optional per-vertex arrays, when present, are one entry per point.
            if let uvs = mesh.vertexUVs { #expect(uvs.count == mesh.points.count) }
            if let normals = mesh.vertexNormals { #expect(normals.count == mesh.points.count) }
            if let colors = mesh.vertexColors { #expect(colors.count == mesh.points.count) }
            // Every triangle references a real vertex.
            for tri in mesh.triangles {
                #expect(Int(tri.v0) < mesh.points.count)
                #expect(Int(tri.v1) < mesh.points.count)
                #expect(Int(tri.v2) < mesh.points.count)
            }
            // Texture references stay within the texture table.
            #expect(mesh.internalTextureID < file.textures.count)
        }

        // Every group references real meshes.
        for group in file.topLevelGroups {
            for meshIndex in group {
                #expect(meshIndex >= 0 && meshIndex < file.meshes.count)
            }
        }
    }
}

@Test func texturesDecodeToTrimmedImages() throws {
    for url in modelURLs() {
        let file = try MetaFile3D(parsing3DMF: try Data(contentsOf: url))
        for texture in file.textures {
            guard let pixmap = texture.pixmap else { continue }
            #expect(pixmap.width > 0 && pixmap.height > 0)
            #expect(pixmap.rowBytes == pixmap.width * (pixmap.pixelSize / 8))
            #expect(pixmap.image.count == pixmap.rowBytes * pixmap.height)
        }
    }
}
