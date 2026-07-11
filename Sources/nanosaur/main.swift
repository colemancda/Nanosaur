// main.swift - Executable entry point. Opens the game window and runs the main
// loop. (The original entry point is main() in src/Boot.cpp.)
import Foundation
import NanosaurApp
import QD3DFile

/// Loads a .3dmf model's meshes as renderables, if the file exists. While the
/// full engine is being ported the executable acts as a model viewer: it shows
/// the first model it finds so there's something on screen.
private func loadDemoModel() -> RenderableModel? {
    // Allow overriding which model to view: NANOSAUR_MODEL=path
    let env = ProcessInfo.processInfo.environment
    var candidates = ["Data/Skeletons/Rex.3dmf", "Data/Models/Title.3dmf", "Data/Models/Global_Models.3dmf"]
    if let override = env["NANOSAUR_MODEL"] { candidates.insert(override, at: 0) }

    let fm = FileManager.default
    for path in candidates where fm.fileExists(atPath: path) {
        guard let data = fm.contents(atPath: path),
              let file = try? MetaFile3D(parsing3DMF: data),
              !file.meshes.isEmpty
        else { continue }
        return RenderableModel(file)
    }
    return nil
}

// Optional headless/testing knobs: run a fixed number of frames and/or capture
// a screenshot (used to verify the build renders without a display).
let env = ProcessInfo.processInfo.environment
let maxFrames = env["NANOSAUR_MAX_FRAMES"].flatMap { Int($0) }
let screenshotPath = env["NANOSAUR_SCREENSHOT"]

do {
    let window = try GameWindow()
    window.model = loadDemoModel()
    window.run(maxFrames: maxFrames, screenshotPath: screenshotPath)
} catch {
    FileHandle.standardError.write(Data("Nanosaur failed to start: \(error)\n".utf8))
    exit(1)
}
