// swift-tools-version: 6.2
import PackageDescription

// NOTE: this package currently only defines the standalone, independently
// tested parser libraries for Nanosaur's data files. The full game port
// (a CNanosaurCore C surface + NanosaurSwift port + executable entry point,
// mirroring the CMake build) is not defined here yet - it will be added
// incrementally as the C code is ported to Swift, the same bottom-up
// approach used by the Nanosaur2 port. The existing CMake build
// (CMakeLists.txt) remains the way to build the playable game for now.

let package = Package(
    name: "Nanosaur",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "ResourceFile", type: .static, targets: ["ResourceFile"]),
        .library(name: "TGAFile", type: .static, targets: ["TGAFile"]),
        .library(name: "SkeletonFile", type: .static, targets: ["SkeletonFile"]),
        .library(name: "TerrainFile", type: .static, targets: ["TerrainFile"]),
        .library(name: "QD3DFile", type: .static, targets: ["QD3DFile"]),
        .library(name: "QD3DMath", type: .static, targets: ["QD3DMath"]),
        .library(name: "NanosaurPlatform", type: .static, targets: ["NanosaurPlatform"]),
        .library(name: "NanosaurEngine", type: .static, targets: ["NanosaurEngine"]),
        .library(name: "NanosaurSkeleton", type: .static, targets: ["NanosaurSkeleton"]),
        .library(name: "NanosaurApp", type: .static, targets: ["NanosaurApp"]),
        .executable(name: "nanosaur", targets: ["nanosaur"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-binary-parsing", from: "0.0.2")
    ],
    targets: [
        // MARK: - ResourceFile (standalone, tested classic-Mac resource-fork parser)

        .target(
            name: "ResourceFile",
            dependencies: [
                .product(name: "BinaryParsing", package: "swift-binary-parsing")
            ]
        ),
        .testTarget(
            name: "ResourceFileTests",
            dependencies: ["ResourceFile"]
        ),

        // MARK: - TGAFile (standalone, tested TGA image decoder)

        .target(
            name: "TGAFile",
            dependencies: [
                .product(name: "BinaryParsing", package: "swift-binary-parsing")
            ]
        ),
        .testTarget(
            name: "TGAFileTests",
            dependencies: ["TGAFile"]
        ),

        // MARK: - SkeletonFile (skeleton + animation decoder built on ResourceFile)

        .target(
            name: "SkeletonFile",
            dependencies: [
                "ResourceFile",
                .product(name: "BinaryParsing", package: "swift-binary-parsing"),
            ]
        ),
        .testTarget(
            name: "SkeletonFileTests",
            dependencies: ["SkeletonFile"]
        ),

        // MARK: - TerrainFile (standalone, tested .ter/.trt terrain parsers)

        .target(
            name: "TerrainFile",
            dependencies: [
                .product(name: "BinaryParsing", package: "swift-binary-parsing")
            ]
        ),
        .testTarget(
            name: "TerrainFileTests",
            dependencies: ["TerrainFile"]
        ),

        // MARK: - QD3DFile (standalone 3DMF model parser)

        .target(
            name: "QD3DFile"
        ),
        .testTarget(
            name: "QD3DFileTests",
            dependencies: ["QD3DFile"]
        ),

        // MARK: - QD3DMath (core 3D math + geometry types)

        .target(
            name: "QD3DMath"
        ),
        .testTarget(
            name: "QD3DMathTests",
            dependencies: ["QD3DMath"]
        ),

        // MARK: - Platform layer (SDL3 + OpenGL system libraries, linked from Swift)

        .systemLibrary(
            name: "CSDL3",
            path: "Sources/CSDL3",
            pkgConfig: "sdl3",
            providers: [.apt(["libsdl3-dev"]), .brew(["sdl3"])]
        ),
        .systemLibrary(
            name: "COpenGL",
            path: "Sources/COpenGL",
            pkgConfig: "gl",
            providers: [.apt(["libgl1-mesa-dev"])]
        ),
        .target(
            name: "NanosaurPlatform",
            dependencies: ["CSDL3", "COpenGL", "QD3DMath"]
        ),
        .testTarget(
            name: "NanosaurPlatformTests",
            dependencies: ["NanosaurPlatform"]
        ),

        // MARK: - NanosaurEngine (ObjNode object system + game loop core)

        .target(
            name: "NanosaurEngine",
            dependencies: ["QD3DMath"]
        ),
        .testTarget(
            name: "NanosaurEngineTests",
            dependencies: ["NanosaurEngine"]
        ),

        // MARK: - NanosaurApp (SDL window + GL context + main loop) and executable

        // MARK: - NanosaurSkeleton (skeletal animation + skinning)

        .target(
            name: "NanosaurSkeleton",
            dependencies: ["QD3DFile", "SkeletonFile", "QD3DMath"]
        ),
        .testTarget(
            name: "NanosaurSkeletonTests",
            dependencies: ["NanosaurSkeleton", "QD3DFile", "SkeletonFile"]
        ),

        .target(
            name: "NanosaurApp",
            dependencies: ["CSDL3", "COpenGL", "NanosaurEngine", "NanosaurSkeleton", "QD3DMath", "QD3DFile"]
        ),
        .executableTarget(
            name: "nanosaur",
            dependencies: ["NanosaurApp", "NanosaurSkeleton", "QD3DFile", "SkeletonFile"]
        ),
    ],
    cxxLanguageStandard: .cxx20
)
