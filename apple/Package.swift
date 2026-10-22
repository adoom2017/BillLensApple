// swift-tools-version: 6.1
import PackageDescription
import Foundation

let rustBuildMode = ProcessInfo.processInfo.environment["RUST_BUILD_MODE"] ?? "debug"
let includeIOSApp = ProcessInfo.processInfo.environment["BILLLENS_INCLUDE_IOS_SPM"] == "1"

// SwiftPM 默认只构建宿主 macOS app，避免 macOS swift build 链接 iOS Rust 库。
// 需要直接用 SwiftPM 构建 iOS target 时，设置 BILLLENS_INCLUDE_IOS_SPM=1。
// RUST_TARGET 仅影响 BillLensIOSApp 的链接路径，BillLensMacApp 始终链接 macOS 库。
//   未设置          → BillLensIOSApp 默认 ios-sim
//   "ios-sim"         → aarch64-apple-ios-sim
//   "ios"             → aarch64-apple-ios
let rustTarget = ProcessInfo.processInfo.environment["RUST_TARGET"] ?? "ios-sim"
let macosLibPath = "../rust/target/\(rustBuildMode)"
let iosLibPath: String = {
    switch rustTarget {
    case "ios":  return "../rust/target/aarch64-apple-ios/\(rustBuildMode)"
    case "ios-sim": return "../rust/target/aarch64-apple-ios-sim/\(rustBuildMode)"
    default: fatalError("RUST_TARGET must be ios or ios-sim")
    }
}()

var products: [Product] = [
    .executable(name: "BillLensMacApp", targets: ["BillLensMacApp"]),
    .library(name: "BillLensShared", targets: ["BillLensShared"]),
    .library(name: "BillLensAppleServices", targets: ["BillLensAppleServices"]),
]

var targets: [Target] = [
    .target(
        name: "CBillLensRustBridge",
        publicHeadersPath: "include"
    ),
    .target(
        name: "BillLensAppleServices",
        dependencies: ["llama"],
        resources: [.process("Resources")]
    ),
    // BillLensShared 只声明框架依赖，Rust 静态库由各自的 executable 链接
    .target(
        name: "BillLensShared",
        dependencies: ["CBillLensRustBridge", "BillLensAppleServices"],
        linkerSettings: [
            .linkedFramework("Speech"),
            .linkedFramework("AVFoundation"),
            .linkedFramework("Vision"),
            .linkedFramework("CloudKit"),
            .linkedFramework("AppKit", .when(platforms: [.macOS])),
            .linkedFramework("UIKit", .when(platforms: [.iOS])),
        ]
    ),
    // macOS 可执行文件：始终链接 macOS Rust 静态库
    .executableTarget(
        name: "BillLensMacApp",
        dependencies: ["BillLensShared", "BillLensAppleServices"],
        exclude: ["AppIcon.icns", "Assets.xcassets", "BillLensMacApp.entitlements", "Info.plist"],
        linkerSettings: [
            .unsafeFlags(["-L", macosLibPath, "-lbilllens_ffi"]),
        ]
    ),
    .binaryTarget(
        name: "llama",
        url: "https://github.com/ggml-org/llama.cpp/releases/download/b9632/llama-b9632-xcframework.zip",
        checksum: "a5f03d5dc7dcf30aa22b4def2540b7b59ed1f65fcd9beb1c37bc7875ddae17e8"
    ),
    .testTarget(
        name: "BillLensAppleServicesTests",
        dependencies: ["BillLensAppleServices"]
    ),
    .testTarget(
        name: "BillLensSharedTests",
        dependencies: ["BillLensShared"],
        linkerSettings: [
            .unsafeFlags(["-L", macosLibPath, "-lbilllens_ffi"]),
        ]
    ),
]

if includeIOSApp {
    products.append(.executable(name: "BillLensIOSApp", targets: ["BillLensIOSApp"]))
    // iOS 可执行文件：链接 iOS Rust 静态库（由 RUST_TARGET 控制 sim / device）
    targets.append(
        .executableTarget(
            name: "BillLensIOSApp",
            dependencies: ["BillLensShared", "BillLensAppleServices"],
            exclude: ["Assets.xcassets", "BillLensIOSApp.entitlements", "Info.plist"],
            linkerSettings: [
                .unsafeFlags(["-L", iosLibPath, "-lbilllens_ffi"]),
            ]
        )
    )
}

let package = Package(
    name: "BillLensApple",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: products,
    targets: targets
)
