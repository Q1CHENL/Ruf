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
    targets: [
        .target(name: "RufCore"),
        .executableTarget(
            name: "Ruf",
            dependencies: ["RufCore"]
        ),
        .testTarget(
            name: "RufCoreTests",
            dependencies: ["RufCore"]
        ),
    ]
)
