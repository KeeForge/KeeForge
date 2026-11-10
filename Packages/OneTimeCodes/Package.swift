// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "OneTimeCodes",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "OneTimeCodes", targets: ["OneTimeCodes"]),
    ],
    targets: [
        .target(name: "OneTimeCodes"),
        .testTarget(
            name: "OneTimeCodesTests",
            dependencies: ["OneTimeCodes"],
            exclude: ["Fixtures/README.md"]
        ),
    ]
)
