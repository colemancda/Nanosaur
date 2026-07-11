// main.swift - Executable entry point. Opens the game window and runs the main
// loop. (The original entry point is main() in src/Boot.cpp.)
import Foundation
import NanosaurApp

do {
    let window = try GameWindow()
    window.run()
} catch {
    FileHandle.standardError.write(Data("Nanosaur failed to start: \(error)\n".utf8))
    exit(1)
}
