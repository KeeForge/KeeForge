// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SiteMatching",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "SiteMatching", targets: ["SiteMatching"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ameshkov/swift-psl.git", from: "1.1.161"),
    ],
    targets: [
        .target(
            name: "SiteMatching",
            dependencies: [
                .product(name: "PublicSuffixList", package: "swift-psl"),
            ]
        ),
        .testTarget(
            name: "SiteMatchingTests",
            dependencies: ["SiteMatching"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
