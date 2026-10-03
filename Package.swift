// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "vncx",
    platforms: [.macOS(.v15)],
    targets: [
        .systemLibrary(name: "CZlib", path: "Sources/CZlib"),
        // RFB protocol, auth, and decoders. No UI dependencies.
        .target(
            name: "VNCCore",
            dependencies: ["CZlib"],
            path: "Sources/VNCCore",
            swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]
        ),
        .executableTarget(
            name: "vncx",
            dependencies: ["VNCCore"],
            path: "Sources/vncx"
        ),
        // Headless client for integration testing against real servers.
        .executableTarget(
            name: "vncx-probe",
            dependencies: ["VNCCore"],
            path: "Sources/vncx-probe"
        ),
        .executableTarget(
            name: "vncx-tests",
            dependencies: ["VNCCore", "CZlib"],
            path: "Sources/vncx-tests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
