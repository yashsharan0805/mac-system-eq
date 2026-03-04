// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "MacSystemEQ",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AudioCaptureKit", targets: ["AudioCaptureKit"]),
        .library(name: "AudioPipelineKit", targets: ["AudioPipelineKit"]),
        .library(name: "PresetsKit", targets: ["PresetsKit"]),
        .library(name: "DeviceKit", targets: ["DeviceKit"]),
        .library(name: "DiagnosticsKit", targets: ["DiagnosticsKit"]),
        .executable(name: "MacSystemEQApp", targets: ["MacSystemEQApp"])
    ],
    targets: [
        .target(
            name: "DiagnosticsKit",
            path: "packages/DiagnosticsKit/Sources/DiagnosticsKit"
        ),
        .target(
            name: "DeviceKit",
            dependencies: ["DiagnosticsKit"],
            path: "packages/DeviceKit/Sources/DeviceKit"
        ),
        .target(
            name: "AudioPipelineKit",
            dependencies: ["DiagnosticsKit", "DeviceKit"],
            path: "packages/AudioPipelineKit/Sources/AudioPipelineKit"
        ),
        .target(
            name: "AudioCaptureKit",
            dependencies: ["DiagnosticsKit", "DeviceKit"],
            path: "packages/AudioCaptureKit/Sources/AudioCaptureKit"
        ),
        .target(
            name: "PresetsKit",
            dependencies: ["AudioPipelineKit", "DiagnosticsKit"],
            path: "packages/PresetsKit/Sources/PresetsKit"
        ),
        .executableTarget(
            name: "MacSystemEQApp",
            dependencies: ["AudioCaptureKit", "AudioPipelineKit", "PresetsKit", "DeviceKit", "DiagnosticsKit"],
            path: "apps/MacSystemEQApp/Sources/MacSystemEQApp",
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .testTarget(
            name: "AudioPipelineKitTests",
            dependencies: ["AudioPipelineKit"],
            path: "packages/AudioPipelineKit/Tests/AudioPipelineKitTests"
        ),
        .testTarget(
            name: "PresetsKitTests",
            dependencies: ["PresetsKit", "AudioPipelineKit"],
            path: "packages/PresetsKit/Tests/PresetsKitTests"
        ),
        .testTarget(
            name: "DeviceKitTests",
            dependencies: ["DeviceKit"],
            path: "packages/DeviceKit/Tests/DeviceKitTests"
        ),
        .testTarget(
            name: "DiagnosticsKitTests",
            dependencies: ["DiagnosticsKit"],
            path: "packages/DiagnosticsKit/Tests/DiagnosticsKitTests"
        ),
        .testTarget(
            name: "AudioCaptureKitTests",
            dependencies: ["AudioCaptureKit"],
            path: "packages/AudioCaptureKit/Tests/AudioCaptureKitTests"
        )
    ]
)
