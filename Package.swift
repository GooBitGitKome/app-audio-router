// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppAudioRouter",
    platforms: [
        .macOS("14.2")
    ],
    products: [
        .library(
            name: "AppAudioRouterCore",
            targets: ["AppAudioRouterCore"]
        ),
        .executable(
            name: "AppAudioRouterApp",
            targets: ["AppAudioRouterApp"]
        ),
        .executable(
            name: "AppAudioRouterCLI",
            targets: ["AppAudioRouterCLI"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "AppAudioRouterCore",
            dependencies: [],
            path: "Sources/AppAudioRouterCore"
        ),
        .executableTarget(
            name: "AppAudioRouterApp",
            dependencies: ["AppAudioRouterCore"],
            path: "Sources/AppAudioRouterApp"
        ),
        .executableTarget(
            name: "AppAudioRouterCLI",
            dependencies: ["AppAudioRouterCore"],
            path: "Sources/AppAudioRouterCLI"
        ),
        .testTarget(
            name: "AppAudioRouterTests",
            dependencies: ["AppAudioRouterCore"],
            path: "Tests/AppAudioRouterTests"
        )
    ]
)
