import Foundation
import Testing

@testable import TGAFile

// Reads the real .tga assets directly from Data/Images and Data/Sprites - see
// ResourceFileTests.swift for the same fixture pattern.
private func dataDir() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // TGAFileTests.swift -> TGAFileTests/
        .deletingLastPathComponent() // TGAFileTests/ -> Tests/
        .deletingLastPathComponent() // Tests/ -> repo root
        .appendingPathComponent("Data")
}

private func tgaURLs() -> [URL] {
    let fm = FileManager.default
    return ["Images", "Sprites"].flatMap { subdir -> [URL] in
        let dir = dataDir().appendingPathComponent(subdir)
        guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "tga" }
    }.sorted { $0.lastPathComponent < $1.lastPathComponent }
}

private func loadImage(_ name: String) throws -> TGAImage {
    let url = tgaURLs().first { $0.lastPathComponent == name }!
    return try TGAImage(parsing: try Data(contentsOf: url))
}

@Test func allFixturesDecodeToARGB() throws {
    let urls = tgaURLs()
    #expect(!urls.isEmpty)
    for url in urls {
        let image = try TGAImage(parsing: try Data(contentsOf: url))
        #expect(image.width > 0)
        #expect(image.height > 0)
        // Always normalized to 32-bit ARGB.
        #expect(image.pixelsARGB.count == image.width * image.height * 4,
                "\(url.lastPathComponent) pixel buffer size mismatch")
    }
}

@Test func knownDimensions() throws {
    let boot = try loadImage("Boot1.tga") // RLE color-mapped, 8bpp
    #expect(boot.width == 640 && boot.height == 480)

    let infobar = try loadImage("Infobar.tga") // RLE true-color BGR, 24bpp
    #expect(infobar.width == 640 && infobar.height == 480)

    let sprite = try loadImage("Infobar1000.tga") // RLE true-color BGRA, 32bpp
    #expect(sprite.width == 64 && sprite.height == 64)
}

@Test func grayscaleDecodesToNeutralOpaquePixels() throws {
    // Shadow.tga is RLE grayscale (8bpp): every decoded pixel must be fully
    // opaque with equal R/G/B. This independently verifies the RLE decode and
    // the grayscale->ARGB path.
    let shadow = try loadImage("Shadow.tga")
    #expect(shadow.width == 64 && shadow.height == 64)
    let px = shadow.pixelsARGB
    for p in stride(from: 0, to: px.count, by: 4) {
        #expect(px[p] == 0xFF, "alpha should be opaque")
        #expect(px[p + 1] == px[p + 2] && px[p + 2] == px[p + 3], "R/G/B should be equal for grayscale")
    }
}
