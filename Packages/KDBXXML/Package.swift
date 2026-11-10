// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "KDBXXML",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "KDBXXML", targets: ["KDBXXML"]),
    ],
    dependencies: [
        .package(path: "../KDBXKit"),
    ],
    targets: [
        .target(
            name: "KDBXXML",
            dependencies: ["KDBXKit"]
        ),
        .testTarget(
            name: "KDBXXMLTests",
            dependencies: ["KDBXXML", "KDBXKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
