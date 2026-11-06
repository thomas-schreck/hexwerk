// swift-tools-version: 6.2
import Foundation
import PackageDescription

// Homebrew prefix for the YARA-X and libmagic headers and static libraries:
// $HOMEBREW_PREFIX if set, else the default location for this Mac.
let brew = ProcessInfo.processInfo.environment["HOMEBREW_PREFIX"]
    ?? (FileManager.default.fileExists(atPath: "/opt/homebrew/include") ? "/opt/homebrew" : "/usr/local")
let brewHeaders: [SwiftSetting] = [.unsafeFlags(["-Xcc", "-I\(brew)/include"])]

// Command Line Tools without Xcode ship the swift-testing macro plugin in a
// folder the compiler does not search, so @Test fails with "plugin for module
// 'TestingMacros' not found". Only add it when the CLT are the
// active developer directory; with Xcode it is found automatically.
let developerDir = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
    ?? (try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link")) ?? ""
let cltTestingPlugins = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
let testSettings: [SwiftSetting] =
    developerDir.contains("CommandLineTools") && FileManager.default.fileExists(atPath: cltTestingPlugins)
    ? [.unsafeFlags(["-plugin-path", cltTestingPlugins])] : []

let package = Package(
    name: "hexwerk",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "hexwerk", targets: ["hexwerk"]),
        .executable(name: "HexwerkApp", targets: ["HexwerkApp"]),
        .library(name: "HexwerkCore", targets: ["HexwerkCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.6.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.0"),
    ],
    targets: [
        .target(name: "HexwerkCore"),
        // Kaitai Struct: .ksy schemas interpreted at runtime.
        .target(name: "HexwerkKaitai", dependencies: ["HexwerkCore", "Yams"]),
        // YARA-X: C API header plus a thin Swift wrapper. The
        // static libyara_x_capi.a is linked in, so neither the CLI nor the app
        // need Homebrew at runtime and a brew upgrade cannot break them (R-5).
        .systemLibrary(name: "CYaraX", path: "Sources/CYaraX"),
        .target(
            name: "HexwerkYARA",
            dependencies: ["HexwerkCore", "CYaraX"],
            swiftSettings: brewHeaders,
            linkerSettings: [
                .unsafeFlags(["\(brew)/lib/libyara_x_capi.a"]),
                .linkedLibrary("iconv"),
            ]
        ),
        // libmagic for file type descriptions, static like YARA-X.
        .systemLibrary(name: "CMagic", path: "Sources/CMagic"),
        .target(
            name: "HexwerkMagic",
            dependencies: ["HexwerkCore", "CMagic"],
            swiftSettings: brewHeaders,
            linkerSettings: [
                .unsafeFlags(["\(brew)/lib/libmagic.a"]),
                .linkedLibrary("z"), .linkedLibrary("bz2"), .linkedLibrary("lzma"),
            ]
        ),
        // JavaScript automation on the system JavaScriptCore.
        .target(name: "HexwerkScript", dependencies: ["HexwerkCore"]),
        .executableTarget(
            name: "hexwerk",
            dependencies: [
                "HexwerkCore", "HexwerkKaitai", "HexwerkYARA", "HexwerkScript", "HexwerkMagic",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: brewHeaders      // dependency scanning sees CYaraX/CMagic too
        ),
        // The macOS app. Built as a plain executable; `make app` wraps it into
        // hexwerk.app (no Xcode project).
        .executableTarget(
            name: "HexwerkApp",
            dependencies: ["HexwerkCore", "HexwerkKaitai", "HexwerkYARA", "HexwerkScript", "HexwerkMagic"],
            swiftSettings: brewHeaders
        ),
        .testTarget(
            name: "HexwerkCoreTests",
            dependencies: ["HexwerkCore", "HexwerkKaitai", "HexwerkYARA", "HexwerkScript", "HexwerkMagic"],
            resources: [.copy("Fixtures")],
            swiftSettings: brewHeaders + testSettings
        ),
    ]
)
