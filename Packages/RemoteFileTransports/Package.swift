// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RemoteFileTransports",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "RemoteFileTransports", targets: ["RemoteFileTransports"]),
    ],
    targets: [
        .target(name: "RemoteFileTransports"),
        // Not a product: the app's test targets compile these sources directly
        // (project.yml), so they see the host app's copy of the package.
        .target(
            name: "RemoteFileTransportsTestSupport",
            dependencies: ["RemoteFileTransports"]
        ),
        .testTarget(
            name: "RemoteFileTransportsTests",
            dependencies: ["RemoteFileTransports", "RemoteFileTransportsTestSupport"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
