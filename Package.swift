// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ScreenRecorder",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ScreenRecorder", targets: ["ScreenRecorder"])
    ],
    targets: [
        .executableTarget(
            name: "ScreenRecorder",
            path: "Sources/ScreenRecorder"
        )
    ]
)
