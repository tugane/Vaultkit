// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Vaultkit",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/tugane/TuganeDesign.git", from: "0.1.0")
    ],
    targets: [
        .executableTarget(
            name: "Vaultkit",
            dependencies: ["TuganeDesign"],
            path: "Sources/Vaultkit"
        ),
        .testTarget(
            name: "VaultkitTests",
            dependencies: ["Vaultkit"],
            path: "Tests/VaultkitTests"
        )
    ]
)
