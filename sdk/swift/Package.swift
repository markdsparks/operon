// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "Operon",
  platforms: [
    .iOS(.v26),
    .macOS(.v26),
  ],
  products: [
    .library(name: "OperonKit", targets: ["OperonKit"]),
    // Development-only bridge to the locally built macOS Rust library. iOS
    // distribution will use the same ABI packaged as an XCFramework.
    .library(name: "OperonCoreFFI", targets: ["OperonCoreFFI"]),
    .library(name: "OperonCoreDriver", targets: ["OperonCoreDriver"]),
    .library(
      name: "OperonFoundationModels",
      targets: ["OperonFoundationModels"]
    ),
    .executable(name: "OperonExpenseDemo", targets: ["OperonExpenseDemo"]),
  ],
  targets: [
    .target(name: "OperonKit"),
    .binaryTarget(
      name: "OperonCoreApple",
      path: "../../artifacts/OperonCore.xcframework"
    ),
    .target(
      name: "OperonCoreFFI",
      dependencies: [
        .target(name: "OperonCoreApple", condition: .when(platforms: [.iOS]))
      ],
      linkerSettings: [
        .unsafeFlags(
          [
            "-L../../target/release",
            "-loperon_core",
            "-Xlinker",
            "-rpath",
            "-Xlinker",
            "../../target/release",
          ],
          .when(platforms: [.macOS])
        )
      ]
    ),
    .target(
      name: "OperonCoreDriver",
      dependencies: ["OperonCoreFFI", "OperonKit"]
    ),
    .target(
      name: "OperonFoundationModels",
      dependencies: ["OperonCoreDriver", "OperonKit"]
    ),
    .executableTarget(
      name: "OperonExpenseDemo",
      dependencies: ["OperonKit", "OperonFoundationModels"]
    ),
    .testTarget(
      name: "OperonKitTests",
      dependencies: ["OperonKit", "OperonCoreDriver", "OperonCoreFFI"]
    ),
  ]
)
