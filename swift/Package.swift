// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "opencua-helper",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "opencua-helper",
            path: "Sources/opencua-helper"
        )
    ]
)
