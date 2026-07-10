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
    ],
    cxxLanguageStandard: .cxx20
)
