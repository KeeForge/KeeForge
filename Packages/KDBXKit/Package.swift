// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "KDBXKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "KDBXKit", targets: ["KDBXKit"]),
    ],
    dependencies: [
        .package(path: "../../Vendor/KeeForgeTwofish"),
        .package(
            url: "https://github.com/P-H-C/phc-winner-argon2.git",
            revision: "f57e61e19229e23c4445b85494dbf7c07de721cb"
        ),
    ],
    targets: [
        .target(
            name: "KDBXKit",
            dependencies: [
                "KeeForgeTwofish",
                .product(name: "argon2", package: "phc-winner-argon2"),
            ]
        ),
    ]
)
