// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MD2",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "MD2Core",
            targets: ["MD2Core"]
        ),
        .library(
            name: "MD2AppSupport",
            targets: ["MD2AppSupport"]
        ),
        .executable(
            name: "Markdown2",
            targets: ["MD2App"]
        )
    ],
    targets: [
        .target(
            name: "MD2Core",
            resources: [
                .copy("Resources/katex"),
                .copy("Resources/diagrams")
            ]
        ),
        .target(
            name: "MD2AppSupport"
        ),
        .executableTarget(
            name: "MD2App",
            dependencies: ["MD2Core", "MD2AppSupport"]
        ),
        .testTarget(
            name: "MD2CoreTests",
            dependencies: ["MD2Core", "MD2AppSupport", "MD2App"],
            exclude: [
                "Matrix",
                "Conformance"
            ],
            resources: [
                .copy("Corpus")
            ]
        )
    ]
)
