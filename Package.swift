// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenAudioMatrix",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(name: "audiomatrix", targets: ["AudioMatrixCLI"]),
        .executable(name: "AudioMatrixEngine", targets: ["AudioMatrixEngine"]),
        .library(name: "AudioMatrixCore", targets: ["AudioMatrixCore"]),
        .library(name: "AudioMatrixCapture", targets: ["AudioMatrixCapture"]),
        .executable(name: "CoreSelfTest", targets: ["CoreSelfTest"]),
        .executable(name: "AudioMatrixApp", targets: ["AudioMatrixApp"]),
    ],
    targets: [
        .target(
            name: "AudioMatrixCore",
            path: "Sources/AudioMatrixCore"
        ),
        .target(
            name: "AudioMatrixCapture",
            dependencies: ["AudioMatrixCore"],
            path: "Sources/AudioMatrixCapture",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AppKit"),
            ]
        ),
        .executableTarget(
            name: "AudioMatrixEngine",
            dependencies: ["AudioMatrixCore", "AudioMatrixCapture"],
            path: "Sources/AudioMatrixEngine"
        ),
        .executableTarget(
            name: "AudioMatrixCLI",
            dependencies: ["AudioMatrixCore"],
            path: "Sources/AudioMatrixCLI"
        ),
        .executableTarget(
            name: "AudioMatrixApp",
            dependencies: ["AudioMatrixCore"],
            path: "Sources/AudioMatrixApp",
            resources: [
                .process("Resources"),
            ],
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
            ]
        ),
        .executableTarget(
            name: "CoreSelfTest",
            dependencies: ["AudioMatrixCore"],
            path: "Sources/CoreSelfTest"
        ),
        .testTarget(
            name: "AudioMatrixCoreTests",
            dependencies: ["AudioMatrixCore"],
            path: "Tests/AudioMatrixCoreTests"
        ),
        .testTarget(
            name: "AudioMatrixCaptureTests",
            dependencies: ["AudioMatrixCapture", "AudioMatrixCore"],
            path: "Tests/AudioMatrixCaptureTests"
        ),
        .testTarget(
            name: "AudioMatrixAppTests",
            dependencies: ["AudioMatrixApp"],
            path: "Tests/AudioMatrixAppTests"
        ),
    ]
)
