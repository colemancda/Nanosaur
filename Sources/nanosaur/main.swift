// main.swift - Executable entry point. Opens the game window and runs the main
// loop. (The original entry point is main() in src/Boot.cpp.)
import Foundation
import NanosaurApp

// Optional headless/testing knobs: run a fixed number of frames and/or capture
// a screenshot (used to verify the build renders without a display).
let env = ProcessInfo.processInfo.environment
let maxFrames = env["NANOSAUR_MAX_FRAMES"].flatMap { Int($0) }
let screenshotPath = env["NANOSAUR_SCREENSHOT"]

do {
    let window = try GameWindow()
    window.run(maxFrames: maxFrames, screenshotPath: screenshotPath)
} catch {
    FileHandle.standardError.write(Data("Nanosaur failed to start: \(error)\n".utf8))
    exit(1)
}
