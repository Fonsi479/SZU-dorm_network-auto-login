// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SZUDormLogin",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "SZUNetCore", targets: ["SZUNetCore"]),
        .library(name: "SZUDormLoginApp", targets: ["SZUDormLoginApp"]),
        .executable(name: "SZUDormLogin", targets: ["SZUDormLogin"]),
    ],
    dependencies: [
        // Command Line Tools installations do not always bundle XCTest/Testing.
        // Keep the official Swift Testing package test-only and version-pinned.
        .package(
            url: "https://github.com/swiftlang/swift-testing.git",
            exact: "0.12.0"
        ),
    ],
    targets: [
        .target(
            name: "SZUNetCore",
            linkerSettings: [
                .linkedFramework("CoreWLAN"),
                .linkedFramework("Security"),
            ]
        ),
        .target(
            name: "SZUDormLoginApp",
            dependencies: ["SZUNetCore"],
            path: "Sources/SZUDormLogin",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .executableTarget(
            name: "SZUDormLogin",
            dependencies: ["SZUDormLoginApp"],
            path: "Sources/SZUDormLoginExecutable"
        ),
        .testTarget(
            name: "SZUNetCoreTests",
            dependencies: [
                "SZUNetCore",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
        .testTarget(
            name: "SZUDormLoginAppTests",
            dependencies: [
                "SZUDormLoginApp",
                "SZUNetCore",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
