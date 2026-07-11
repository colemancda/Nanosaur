// HUD.swift - The in-game infobar, ported from src/Screens/Infobar.c. Draws the
// Infobar.tga backdrop plus sprite frames (weapon icon, score/lives digits,
// fuel gauge) and the health meter as a 2D overlay, at the original screen
// coordinates. Sprite frames come from Data/Sprites/Infobar<1000+frame>.tga.
import Foundation
import TGAFile

// Sprite frame numbers (objtypes.h).
private enum Frame {
    static let weaponBlaster = 0 // weapons occupy 0...4
    static let digit0 = 5        // digits 0-9 -> frames 5...14
    static let fuelGauge = 16    // 29 gauge states -> frames 16...44
}

// Layout constants (Infobar.c).
private enum Layout {
    static let weaponIconX: Float = 21, weaponIconY: Float = 133
    static let scoreX: Float = 270, scoreY: Float = 419
    static let livesX: Float = 51, livesY: Float = 458
    static let fuelX: Float = 52 - 14, fuelY: Float = 327 - 53
    static let numbersXOff: Float = -7, numbersYOff: Float = -6, numbersWidth: Float = 16
    static let maxFuel = 28
    static let healthMeterX: Float = 189, healthMeterY: Float = 457
    static let healthMeterWidth: Float = 213, healthMeterHeight: Float = 9
}

public final class HUD {
    private struct Sprite { let texture: Texture2D; let width: Float; let height: Float }

    private let backdrop: Sprite
    private var frames: [Int: Sprite] = [:]

    // Game state shown by the bar.
    public var score: UInt = 0
    public var lives: Int = 2
    public var fuel: Int = Layout.maxFuel // 0...28
    public var health: Float = 1           // 0...1
    public var weapon: Int = 0             // 0...4

    /// Loads the backdrop + all infobar sprite frames from the data folder.
    public init?(dataDir: String) {
        guard let backdrop = HUD.loadSprite("\(dataDir)/Images/Infobar.tga") else { return nil }
        self.backdrop = backdrop
        for frame in 0..<50 {
            if let s = HUD.loadSprite("\(dataDir)/Sprites/Infobar\(1000 + frame).tga") {
                frames[frame] = s
            }
        }
    }

    /// Loads a TGA as a sprite, converting ARGB->RGBA. Fully-opaque sprites
    /// (24-bit digits, the backdrop) get pure black keyed to transparent, which
    /// matches the game's sprite masks and lets the 3D scene show through.
    private static func loadSprite(_ path: String) -> Sprite? {
        guard let data = FileManager.default.contents(atPath: path),
              let image = try? TGAImage(parsing: data) else { return nil }
        let argb = image.pixelsARGB
        let count = image.width * image.height

        var opaque = true
        var i = 0
        while i < argb.count { if argb[i] != 255 { opaque = false; break }; i += 4 }

        var rgba = [UInt8](repeating: 0, count: count * 4)
        for p in 0..<count {
            let a = argb[p * 4 + 0], r = argb[p * 4 + 1], g = argb[p * 4 + 2], b = argb[p * 4 + 3]
            rgba[p * 4 + 0] = r; rgba[p * 4 + 1] = g; rgba[p * 4 + 2] = b
            rgba[p * 4 + 3] = (opaque && r < 8 && g < 8 && b < 8) ? 0 : a
        }
        guard let tex = Texture2D(rgba: rgba, width: image.width, height: image.height) else { return nil }
        return Sprite(texture: tex, width: Float(image.width), height: Float(image.height))
    }

    public func draw(with renderer: Renderer) {
        renderer.begin2D()

        renderer.draw2D(backdrop.texture.name, x: 0, y: 0, width: backdrop.width, height: backdrop.height)

        drawFrame(Frame.weaponBlaster + weapon, x: Layout.weaponIconX, y: Layout.weaponIconY, with: renderer)
        drawFrame(Frame.fuelGauge + (Layout.maxFuel - max(0, min(Layout.maxFuel, fuel))),
                  x: Layout.fuelX, y: Layout.fuelY, with: renderer)
        printNumber(score, digits: 8, x: Layout.scoreX, y: Layout.scoreY, with: renderer)
        printNumber(UInt(max(0, lives)), digits: 1, x: Layout.livesX, y: Layout.livesY, with: renderer)

        // Health meter: a dark-red bar whose width tracks health.
        let w = max(0, min(1, health)) * Layout.healthMeterWidth
        renderer.fillRect2D(x: Layout.healthMeterX, y: Layout.healthMeterY,
                            width: w, height: Layout.healthMeterHeight,
                            r: 0.56, g: 0, b: 0.03)

        renderer.end2D()
    }

    private func drawFrame(_ frame: Int, x: Float, y: Float, with renderer: Renderer) {
        guard let s = frames[frame] else { return }
        renderer.draw2D(s.texture.name, x: x, y: y, width: s.width, height: s.height)
    }

    /// Draws `num` right-aligned as `digits` sprite digits ending at (x, y).
    private func printNumber(_ num: UInt, digits: Int, x: Float, y: Float, with renderer: Renderer) {
        var n = num
        var px = x + Layout.numbersXOff
        let py = y + Layout.numbersYOff
        for _ in 0..<digits {
            let digit = Int(n % 10)
            n /= 10
            drawFrame(Frame.digit0 + digit, x: px, y: py, with: renderer)
            px -= Layout.numbersWidth
        }
    }
}
