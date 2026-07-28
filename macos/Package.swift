// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SZUDormLogin",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "SZUNetCore", targets: ["SZUNetCore"]),
        .library(name: "SZUNETFeature", targets: ["SZUNETFeature"]),
        .library(name: "SZUDormLoginApp", targets: ["SZUDormLoginApp"]),
        .executable(name: "SZUDormLogin", targets: ["SZUDormLogin"]),
        .executable(name: "szu-campus-netctl", targets: ["SZUCampusNetctl"]),
    ],
    dependencies: [
        // Command Line Tools installations do not always bundle XCTest/Testing.
        // Keep the official Swift Testing package test-only and version-pinned.
        .package(
            url: "https://github.com/swiftlang/swift-testing.git",
            exact: "6.3.2"
        ),
    ],
    targets: [
        .target(
            name: "SZUNetCore",
            dependencies: [],
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
                .linkedFramework("Network"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .target(
            name: "SZUNETFeature",
            dependencies: [],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
            ]
        ),
        .executableTarget(
            name: "SZUDormLogin",
            dependencies: ["SZUDormLoginApp"],
            path: "Sources/SZUDormLoginExecutable"
        ),
        .executableTarget(
            name: "SZUCampusNetctl",
            dependencies: ["SZUNetCore"],
            path: "Sources/SZUCampusNetctl",
            linkerSettings: [.linkedFramework("AppKit")]
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
        .testTarget(
            name: "SZUNETFeatureTests",
            dependencies: [
                "SZUNETFeature",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
