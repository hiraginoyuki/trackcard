// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TrackpadPreview",
    platforms: [.macOS(.v14)],
    products: [.library(name: "TrackpadCore", targets: ["TrackpadCore"])],
    targets: [
        .target(
            name: "TrackpadBridge",
            publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("CoreFoundation"), .linkedFramework("IOKit")]
        ),
        .target(name: "TrackpadCore"),
        .target(
            name: "TrackpadPreview",
            dependencies: ["TrackpadBridge", "TrackpadCore"],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("QuartzCore")]
        ),
        .testTarget(name: "TrackpadCoreTests", dependencies: ["TrackpadCore"])
    ],
    cxxLanguageStandard: .cxx17
)
