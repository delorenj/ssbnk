// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SSBNKClient",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "SSBNKClient", targets: ["SSBNKClient"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/swiftlang/swift-testing.git",
            revision: "48d727cc1cf4eda667c858c501495f1018f69d21"
        ),
    ],
    targets: [
        .executableTarget(
            name: "SSBNKClient",
            path: "Sources/SSBNKClient"
        ),
        .testTarget(
            name: "SSBNKClientTests",
            dependencies: [
                "SSBNKClient",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests/SSBNKClientTests",
            linkerSettings: [
                .unsafeFlags([
                    "-L/Library/Developer/CommandLineTools/Library/Developer/usr/lib",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib",
                ], .when(platforms: [.macOS])),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
