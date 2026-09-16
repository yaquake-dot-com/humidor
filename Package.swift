// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Humidor, a client for the Soulseek peer-to-peer network. Derived from
// Nicotine+ (https://nicotine-plus.org).

import PackageDescription

let package = Package(
    name: "Humidor",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "HumidorCore", targets: ["HumidorCore"]),
        .executable(name: "humidor-cli", targets: ["humidor-cli"]),
        .executable(name: "Humidor", targets: ["Humidor"])
    ],
    targets: [
        // Protocol, networking and application logic (no UI)
        .target(
            name: "HumidorCore",
            resources: [
                .process("Localizable.xcstrings"),
                // IP2Location LITE data, licensed under CC BY-SA 4.0
                .copy("Resources/ip_country_data.csv")
            ]
        ),
        // Headless command line client
        .executableTarget(
            name: "humidor-cli",
            dependencies: ["HumidorCore"]
        ),
        // macOS application (SwiftUI, with AppKit list views)
        .executableTarget(
            name: "Humidor",
            dependencies: ["HumidorCore"],
            resources: [
                .process("Localizable.xcstrings")
            ]
        ),
        .testTarget(
            name: "HumidorCoreTests",
            dependencies: ["HumidorCore"],
            resources: [
                .copy("Fixtures")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
