// HighScoresScene.swift - The high scores screen, ported from
// src/Screens/HighScores.c. Each of the 8 saved (name, score) entries is laid
// out along +X as a row of individual 3D letter/digit models (there's no font
// texture here - every character is its own mesh from HighScores.3dmf), and
// the camera dollies forward through the list while a decorative spiral model
// rotates behind everything. Name entry for a new high score (EnterPlayerName,
// the in-game text-input flow) isn't ported yet - AddNewScore/persistence are,
// so scores accumulate across runs.
import Foundation
import QD3DFile
import QD3DMath

public final class HighScoresScene {
    // HighScores.3dmf object indices (highscores.h): NameFrame=0, 0-9=1...10,
    // A-Z=11...36, Period=37,Pound=38,Question=39,Exclamation=40,Dash=41,
    // Apostrophe=42,Colon=43, Cursor=44, Spiral=45.
    private enum Obj {
        static let digit0 = 1
        static let letterA = 11
        static let period = 37, pound = 38, question = 39, exclamation = 40
        static let dash = 41, apostrophe = 42, colon = 43
        static let spiral = 45
    }

    private static let numScores = 8
    private static let maxNameLength = 11
    private static let letterSeparation: Float = 18
    private static let leftEdge: Float = -100

    public struct Entry: Codable {
        public var name: String
        public var score: UInt
    }

    let model: RenderableModel
    public private(set) var entries: [Entry]

    /// Camera dolly: eye starts at (-110,-30,90); each frame the same delta is
    /// added to both eye and look-at (QD3D_MoveCameraFromTo), so the camera
    /// pans in +X without changing view direction, until eye.x reaches 2200.
    public var eye = Point3D(x: -110, y: -30, z: 90)
    public var lookAt = Point3D(x: 0, y: 0, z: 0)
    public var spiralRotX: Float = 0
    private let savePath: String

    // Camera (HighScores.c SetupHighScoresScreen): fov 1.1 rad, hither 5, yon 2000.
    public let fovDegrees: Float = 63

    public init?(dataDir: String, savePath: String = "Nanosaur_HighScores.json") {
        let fm = FileManager.default
        guard let md = fm.contents(atPath: "\(dataDir)/Models/HighScores.3dmf"),
              let file = try? MetaFile3D(parsing3DMF: md)
        else { return nil }
        model = RenderableModel(file)
        self.savePath = savePath
        entries = HighScoresScene.load(from: savePath)
    }

    private static func load(from path: String) -> [Entry] {
        if let data = FileManager.default.contents(atPath: path),
           let saved = try? JSONDecoder().decode([Entry].self, from: data), saved.count == numScores {
            return saved
        }
        return (0..<numScores).map { _ in Entry(name: "", score: 0) } // ClearHighScores
    }

    public func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: URL(fileURLWithPath: savePath))
    }

    /// AddNewScore: insert a score in sorted position under `name`, dropping
    /// the lowest entry, then persist. No-ops if it doesn't beat any entry
    /// (matches the original silently ignoring non-qualifying scores).
    public func addScore(name: String, score: UInt) {
        guard let slot = entries.firstIndex(where: { score > $0.score }) else { return }
        entries.insert(Entry(name: String(name.prefix(HighScoresScene.maxNameLength)), score: score), at: slot)
        entries.removeLast()
        save()
    }

    /// Advance the camera dolly + spiral spin. Returns true once the scroll
    /// has reached the end of the list (matches the original's exit condition
    /// `cameraLocation.x < 2200`).
    @discardableResult
    public func update(dt: Float) -> Bool {
        let delta = dt * 70
        eye.x += delta
        lookAt.x += delta
        spiralRotX += dt * 1.5
        return eye.x >= 2200
    }

    private func objectForChar(_ c: Character) -> Int? {
        if let d = c.wholeNumberValue, c.isNumber { return Obj.digit0 + d }
        let upper = Character(c.uppercased())
        if upper.isLetter, let ascii = upper.asciiValue, ascii >= 65, ascii <= 90 {
            return Obj.letterA + Int(ascii - 65)
        }
        switch c {
        case "#": return Obj.pound
        case "!": return Obj.exclamation
        case "?": return Obj.question
        case "'": return Obj.apostrophe
        case ".": return Obj.period
        case ":": return Obj.colon
        case "-": return Obj.dash
        default: return nil
        }
    }

    /// All (object, transform) placements for this frame: every row's name
    /// letters + score digits, laid out exactly like PrepHighScoresShow.
    public func placements() -> [(object: Int, transform: Matrix4x4)] {
        var result: [(Int, Matrix4x4)] = []
        for (slot, entry) in entries.enumerated() {
            let rowX = HighScoresScene.letterSeparation * Float(HighScoresScene.maxNameLength + 3) * Float(slot) + 200

            for (i, c) in entry.name.enumerated() where c != " " {
                guard let obj = objectForChar(c) else { continue }
                let x = rowX + Float(i) * HighScoresScene.letterSeparation
                result.append((obj, Matrix4x4.translate(x, 0, 0)))
            }

            var score = entry.score, place = 0
            let scoreX = rowX + 75
            repeat {
                let digit = Int(score % 10)
                score /= 10
                let x = scoreX - Float(place) * HighScoresScene.letterSeparation
                result.append((Obj.digit0 + digit, Matrix4x4.translate(x, -25, 0)))
                place += 1
            } while score > 0 || place < 4
        }
        return result
    }

    public var spiralObject: Int { Obj.spiral }
    public var spiralTransform: Matrix4x4 {
        Matrix4x4.scale(4, 4, 4).multiplied(by: Matrix4x4.rotationX(spiralRotX))
    }
}
