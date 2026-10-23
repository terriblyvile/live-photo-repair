// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "LivePhotoRepair",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "LivePhotoRepair",
            path: "Sources/LivePhotoRepair"
        )
    ],
    swiftLanguageModes: [.v5]
)
