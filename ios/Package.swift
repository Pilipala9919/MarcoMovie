// swift-tools-version: 5.9
// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import Foundation
import PackageDescription

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let jsHostExists = FileManager.default.fileExists(
    atPath: packageDir
        .appendingPathComponent("Sources/MarcoIOSCore/Resources/js-host")
        .path
)
let catpawExists = FileManager.default.fileExists(
    atPath: packageDir
        .appendingPathComponent("Sources/MarcoIOSCore/Resources/catpaw")
        .path
)
let shadersExists = FileManager.default.fileExists(
    atPath: packageDir
        .appendingPathComponent("Sources/MarcoIOSCore/Resources/shaders")
        .path
)
let resourcesReadmeExists = FileManager.default.fileExists(
    atPath: packageDir
        .appendingPathComponent("Sources/MarcoIOSCore/Resources/README.md")
        .path
)

var coreResources: [Resource] = []
if jsHostExists {
    coreResources.append(.copy("Resources/js-host"))
}
if catpawExists {
    coreResources.append(.copy("Resources/catpaw"))
}
if shadersExists {
    coreResources.append(.copy("Resources/shaders"))
}

var coreExcludes: [String] = []
if resourcesReadmeExists {
    coreExcludes.append("Resources/README.md")
}

let package = Package(
    name: "MarcoMovieIOS",
    platforms: [
        .macOS(.v13),
        .iOS(.v14),
    ],
    products: [
        .library(
            name: "MarcoIOSCore",
            targets: ["MarcoIOSCore"]
        ),
    ],
    targets: [
        .target(
            name: "CQuickJS",
            path: "Sources/CQuickJS",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
                .headerSearchPath("include"),
                .define("_GNU_SOURCE"),
                .define("CONFIG_VERSION", to: "\"ng-0.14.0\""),
                .define("NDEBUG", .when(configuration: .release)),
            ]
        ),
        .target(
            name: "MarcoIOSCore",
            dependencies: ["CQuickJS"],
            path: "Sources/MarcoIOSCore",
            exclude: coreExcludes,
            resources: coreResources
        ),
        .testTarget(
            name: "MarcoIOSCoreTests",
            dependencies: ["MarcoIOSCore"],
            path: "Tests/MarcoIOSCoreTests"
        ),
    ],
    cLanguageStandard: .gnu11,
    cxxLanguageStandard: .cxx17
)
