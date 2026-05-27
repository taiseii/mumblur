// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MumblurCore",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "MumblurCore", targets: ["MumblurCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "MumblurCore",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ]
        ),
        .testTarget(
            name: "MumblurCoreTests",
            dependencies: ["MumblurCore"],
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
