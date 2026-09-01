// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Vaultkit",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Vaultkit",
            path: "Sources/Vaultkit"
        )
    ]
)
