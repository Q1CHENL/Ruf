// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Ruf",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .executable(name: "Ruf", targets: ["Ruf"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            from: "2.9.4"
        ),
    ],
    targets: [
        .target(name: "RufCore"),
        .executableTarget(
            name: "Ruf",
            dependencies: [
                "RufCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),
        .testTarget(
            name: "RufCoreTests",
            dependencies: ["RufCore"]
        ),
        .testTarget(
            name: "RufTests",
            dependencies: ["Ruf"]
        ),
    ]
)
