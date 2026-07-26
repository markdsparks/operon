// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "Operon",
  platforms: [
    .iOS(.v16),
    .macOS(.v13),
  ],
  products: [
    .library(name: "OperonKit", targets: ["OperonKit"]),
    .library(name: "OperonCoreFFI", targets: ["OperonCoreFFI"]),
    .library(name: "OperonCoreDriver", targets: ["OperonCoreDriver"]),
    .library(name: "OperonFoundationModels", targets: ["OperonFoundationModels"]),
    .library(name: "OperonSQLite", targets: ["OperonSQLite"]),
  ],
  targets: [
    .binaryTarget(
      name: "OperonCoreApple",
      url:
        "https://github.com/markdsparks/operon/releases/download/v0.4.0/OperonCore.xcframework.zip",
      checksum: "be3ec547d6385dd70db709ae74af2e4edb9afe0918c423402f6079b4b473de68"
    ),
    .target(name: "OperonKit", path: "sdk/swift/Sources/OperonKit"),
    .target(
      name: "OperonCoreFFI",
      dependencies: ["OperonCoreApple"],
      path: "sdk/swift/Sources/OperonCoreFFI"
    ),
    .target(
      name: "OperonCoreDriver",
      dependencies: ["OperonCoreFFI", "OperonKit"],
      path: "sdk/swift/Sources/OperonCoreDriver"
    ),
    .target(
      name: "OperonFoundationModels",
      dependencies: ["OperonCoreDriver", "OperonKit"],
      path: "sdk/swift/Sources/OperonFoundationModels"
    ),
    .target(
      name: "OperonSQLite",
      dependencies: ["OperonCoreDriver", "OperonKit"],
      path: "sdk/swift/Sources/OperonSQLite",
      linkerSettings: [.linkedLibrary("sqlite3")]
    ),
  ]
)
