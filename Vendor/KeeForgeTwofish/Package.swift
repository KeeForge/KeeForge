// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "KeeForgeTwofish",
    platforms: [
        .iOS(.v17),
        .macOS(.v13),
    ],
    products: [
        .library(name: "KeeForgeTwofish", targets: ["KeeForgeTwofish"]),
    ],
    targets: [
        .target(
            name: "CTwofish",
            publicHeadersPath: "include"
        ),
        .target(
            name: "KeeForgeTwofish",
            dependencies: ["CTwofish"]
        ),
    ],
    cLanguageStandard: .c11
)
