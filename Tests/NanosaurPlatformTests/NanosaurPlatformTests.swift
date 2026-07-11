import Testing

@testable import NanosaurPlatform

@Test func sdlLinksAndReportsAModernVersion() {
    // Linking SDL3 and calling into it headlessly (SDL_GetVersion needs no
    // video subsystem). Confirms the CSDL3 system module + link work.
    let version = Platform.sdlLinkedVersion()
    #expect(version >= 3_002_000) // SDL 3.2.0 or newer
}

@Test func openGLConstantIsAvailable() {
    // Referencing a GL constant confirms the COpenGL system module imports.
    #expect(Platform.glColorBufferBit == 0x0000_4000) // GL_COLOR_BUFFER_BIT
}
