// swift-tools-version: 6.1
import PackageDescription
import Foundation

let rustBuildMode = ProcessInfo.processInfo.environment["RUST_BUILD_MODE"] ?? "debug"

// RUST_TARGET 仅影响 BillLensIOSApp 的链接路径，BillLensMacApp 始终链接 macOS 库。
//   未设置 / "macos"  → (BillLensIOSApp 默认 ios-sim)
//   "ios-sim"         → aarch64-apple-ios-sim
//   "ios"             → aarch64-apple-ios
let rustTarget = ProcessInfo.processInfo.environment["RUST_TARGET"] ?? "ios-sim"
let macosLibPath = "../rust/target/\(rustBuildMode)"
let iosLibPath: String = {
    switch rustTarget {
    case "ios":  return "../rust/target/aarch64-apple-ios/\(rustBuildMode)"
    default:     return "../rust/target/aarch64-apple-ios-sim/\(rustBuildMode)"
    }
}()

let package = Package(
    name: "BillLensApple",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "BillLensMacApp", targets: ["BillLensMacApp"]),
        .executable(name: "BillLensIOSApp", targets: ["BillLensIOSApp"]),
        .library(name: "BillLensShared", targets: ["BillLensShared"]),
        .library(name: "BillLensAppleServices", targets: ["BillLensAppleServices"]),
    ],
    targets: [
        .target(
            name: "CBillLensRustBridge",
            publicHeadersPath: "include"
        ),
        .target(
            name: "BillLensAppleServices",
            dependencies: []
        ),
        // BillLensShared 只声明框架依赖，Rust 静态库由各自的 executable 链接
        .target(
            name: "BillLensShared",
            dependencies: ["CBillLensRustBridge", "BillLensAppleServices"],
            linkerSettings: [
                .linkedFramework("Speech"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Vision"),
                .linkedFramework("AppKit", .when(platforms: [.macOS])),
                .linkedFramework("UIKit", .when(platforms: [.iOS])),
            ]
        ),
        // macOS 可执行文件：始终链接 macOS Rust 静态库
        .executableTarget(
            name: "BillLensMacApp",
            dependencies: ["BillLensShared", "BillLensAppleServices"],
            linkerSettings: [
                .unsafeFlags(["-L", macosLibPath, "-lbilllens_ffi"]),
            ]
        ),
        // iOS 可执行文件：链接 iOS Rust 静态库（由 RUST_TARGET 控制 sim / device）
        .executableTarget(
            name: "BillLensIOSApp",
            dependencies: ["BillLensShared", "BillLensAppleServices"],
            linkerSettings: [
                .unsafeFlags(["-L", iosLibPath, "-lbilllens_ffi"]),
            ]
        ),
    ]
)

