// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SZUDormLogin",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SZUNetCore", targets: ["SZUNetCore"]),
        .library(name: "SZUNETFeature", targets: ["SZUNETFeature"]),
        .library(name: "SZUNETEmbedded", targets: ["SZUNETEmbedded"]),
        .library(name: "SZUDormLoginApp", targets: ["SZUDormLoginApp"]),
        .executable(name: "SZUDormLogin", targets: ["SZUDormLogin"]),
        .executable(name: "szu-campus-netctl", targets: ["SZUCampusNetctl"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/swiftlang/swift-testing.git",
            exact: "6.3.2"
        ),
    ],
    targets: [
        .target(
            name: "SZUNetCore",
            path: "macos/Sources/SZUNetCore",
            linkerSettings: [
                .linkedFramework("CoreWLAN"),
                .linkedFramework("Security"),
            ]
        ),
        .target(
            name: "SZUNETFeature",
            dependencies: [],
            path: "macos/Sources/SZUNETFeature",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
            ]
        ),
        .target(
            name: "SZUNETEmbedded",
            dependencies: ["SZUNetCore", "SZUNETFeature"],
            path: "macos/Sources/SZUNETEmbedded",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
            ]
        ),
        .target(
            name: "SZUDormLoginApp",
            dependencies: ["SZUNetCore", "SZUNETEmbedded"],
            path: "macos/Sources/SZUDormLogin",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Network"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .executableTarget(
            name: "SZUDormLogin",
            dependencies: ["SZUDormLoginApp"],
            path: "macos/Sources/SZUDormLoginExecutable"
        ),
        .executableTarget(
            name: "SZUCampusNetctl",
            dependencies: ["SZUNetCore"],
            path: "macos/Sources/SZUCampusNetctl",
            swiftSettings: [.unsafeFlags(["-parse-as-library"])],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .testTarget(
            name: "SZUNetCoreTests",
            dependencies: [
                "SZUNetCore",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "macos/Tests/SZUNetCoreTests"
        ),
        .testTarget(
            name: "SZUDormLoginAppTests",
            dependencies: [
                "SZUDormLoginApp",
                "SZUNetCore",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "macos/Tests/SZUDormLoginAppTests"
        ),
        .testTarget(
            name: "SZUNETFeatureTests",
            dependencies: [
                "SZUNETFeature",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "macos/Tests/SZUNETFeatureTests"
        ),
        .testTarget(
            name: "SZUNETEmbeddedTests",
            dependencies: [
                "SZUNETEmbedded",
                "SZUNETFeature",
                "SZUNetCore",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "macos/Tests/SZUNETEmbeddedTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
