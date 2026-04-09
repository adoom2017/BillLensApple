// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "BillLensApple",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "BillLensMacApp", targets: ["BillLensMacApp"])
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
        .target(
            name: "BillLensShared",
            dependencies: ["CBillLensRustBridge", "BillLensAppleServices"],
            linkerSettings: [
                .unsafeFlags(["-L", "../rust/target/debug", "-lbilllens_ffi"]),
                .linkedFramework("Speech"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Vision"),
                .linkedFramework("AppKit")
            ]
        ),
        .executableTarget(
            name: "BillLensMacApp",
            dependencies: ["BillLensShared", "BillLensAppleServices"]
        )
    ]
)

