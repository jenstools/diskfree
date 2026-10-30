// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "diskfree",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "DiskFree"),
    ]
)
