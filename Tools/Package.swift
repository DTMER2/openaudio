// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "OpenAudioTools",
    platforms: [
        .macOS("14.4")
    ],
    targets: [
        .executableTarget(
            name: "looptest",
            path: "Sources/looptest"
        ),
        .executableTarget(
            name: "tapcapture",
            path: "Sources/tapcapture"
        ),
        .target(
            name: "OpenAudioEngine",
            path: "Sources/OpenAudioEngine"
        ),
        .executableTarget(
            name: "openaudio",
            dependencies: ["OpenAudioEngine"],
            path: "Sources/openaudio"
        ),
    ]
)
