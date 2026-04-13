// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacAgent",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        .library(name: "RemoteDevCore", targets: ["RemoteDevCore"]),
        .library(name: "CPosixHelpers", targets: ["CPosixHelpers"]),
        .library(name: "MacAgentLib", targets: ["MacAgentLib"]),
    ],
    targets: [
        .target(
            name: "CPosixHelpers",
            path: "Sources/CPosixHelpers",
            publicHeadersPath: "include"
        ),
        .target(
            name: "CEditline",
            path: "Sources/CEditline",
            publicHeadersPath: "include",
            linkerSettings: [.linkedLibrary("edit")]
        ),
        .target(
            name: "RemoteDevCore",
            path: "Sources/RemoteDevCore"
        ),
        .target(
            name: "MacAgentLib",
            dependencies: ["CPosixHelpers", "RemoteDevCore"],
            path: "Sources/MacAgentLib"
        ),
        .target(
            name: "BuildKit",
            dependencies: ["RemoteDevCore"],
            path: "Sources/BuildKit"
        ),
        .executableTarget(
            name: "termonmac",
            dependencies: ["CPosixHelpers", "CEditline", "RemoteDevCore", "BuildKit", "MacAgentLib"],
            path: "Sources/MacAgent"
        ),
        .executableTarget(
            name: "BuildCLI",
            dependencies: ["BuildKit", "RemoteDevCore"],
            path: "Sources/BuildCLI"
        ),
        .executableTarget(
            name: "TestPeer",
            dependencies: ["RemoteDevCore"],
            path: "Sources/TestPeer"
        ),
        .testTarget(
            name: "RemoteDevCoreTests",
            dependencies: ["RemoteDevCore"],
            path: "Tests/RemoteDevCoreTests"
        ),
        .testTarget(
            name: "BuildKitTests",
            dependencies: ["BuildKit"],
            path: "Tests/BuildKitTests"
        ),
        .testTarget(
            name: "MacAgentTests",
            dependencies: ["MacAgentLib", "RemoteDevCore"],
            path: "Tests/MacAgentTests"
        ),
    ]
)
