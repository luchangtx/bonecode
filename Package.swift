// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BoneCode",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "BoneCode", targets: ["BoneCode"])
    ],
    targets: [
        .executableTarget(
            name: "BoneCode",
            path: "Sources/BoneCode"
        )
    ]
)
