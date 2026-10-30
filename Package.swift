// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Trackcard",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Trackcard", targets: ["TrackpadPreview"])],
    targets: [
        .target(
            name: "TrackpadBridge",
            publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("CoreFoundation"), .linkedFramework("IOKit")]
        ),
        .target(name: "TrackpadCore"),
        .executableTarget(
            name: "TrackpadPreview",
            dependencies: ["TrackpadBridge", "TrackpadCore"],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("QuartzCore")]
        ),
        .testTarget(name: "TrackpadCoreTests", dependencies: ["TrackpadCore"])
    ],
    cxxLanguageStandard: .cxx17
)
