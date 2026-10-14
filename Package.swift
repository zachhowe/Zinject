// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Zinject",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13),
        .tvOS(.v13),
        .watchOS(.v6),
    ],
    products: [
        // Dynamic, deliberately: PRUF links Zinject from four frameworks plus the app and
        // the test bundle. A static product gets hoisted into a hash-named PackageProduct
        // framework whose symbols the test bundle cannot bind against, and N static copies
        // would give N distinct Container types in one process — a parent chain handed
        // across module boundaries needs ONE shared image. A dynamic product gives every
        // consumer the same boring @rpath linkage the app already uses for OpenSSL.
        .library(
            name: "Zinject",
            type: .dynamic,
            targets: ["Zinject"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "Zinject",
            dependencies: [
                .product(name: "Atomics", package: "swift-atomics"),
            ]
        ),
        .testTarget(
            name: "ZinjectTests",
            dependencies: ["Zinject"]
        ),
        .executableTarget(
            name: "ZinjectBench",
            dependencies: ["Zinject"]
        ),
    ]
)
