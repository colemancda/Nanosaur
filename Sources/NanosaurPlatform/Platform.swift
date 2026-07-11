// Platform.swift - Thin Swift wrapper over the SDL3 + OpenGL system modules.
// This is the seam between the pure-Swift game and the external C libraries it
// links (SDL3 for windowing/input/audio, OpenGL for rendering). As the engine
// is ported, the SDL/GL entry points the game needs land here.
import CSDL3
import COpenGL

public enum Platform {
    /// SDL's linked version number (SDL_VERSIONNUM: major*1_000_000 +
    /// minor*1_000 + patch). Confirms the SDL3 link works at runtime.
    public static func sdlLinkedVersion() -> Int {
        Int(SDL_GetVersion())
    }

    /// A well-known OpenGL bitmask constant, referenced to confirm the GL
    /// headers import and the GL library links.
    public static let glColorBufferBit: UInt32 = UInt32(GL_COLOR_BUFFER_BIT)
}
