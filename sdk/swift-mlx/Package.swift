// swift-tools-version: 6.1
import PackageDescription

// A separate manifest, not a target inside sdk/swift/Package.swift.
//
// SwiftPM enforces platform-deployment floors at the PACKAGE level, not
// per-target — any dependency here would force sdk/swift's declared
// `.iOS(.v16), .macOS(.v13)` up to mlx-swift-lm's own `.iOS(.v17),
// .macOS(.v14)` floor, for every consumer of OperonKit/OperonCoreDriver/
// OperonSQLite, whether or not they touch MLX. That is the same
// "separate product with its own floor" shape sdk/swift/Package.swift
// already gives OperonFoundationModels (iOS 26+/macOS 26+, per the
// CHANGELOG) — carried one level further here because an external SPM
// dependency's floor, unlike a weakly-linked system framework, cannot be
// gated with `@available` alone.
let package = Package(
  name: "OperonMLX",
  platforms: [
    .iOS(.v17),
    .macOS(.v14),
  ],
  products: [
    .library(name: "OperonMLX", targets: ["OperonMLX"])
  ],
  dependencies: [
    .package(path: "../swift"),
    .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", from: "3.0.0"),
    // Not the community `MLXLMTokenizers` package — see the doc comment on
    // `OperonTokenizerLoader` in MLXModelProvider.swift for why: its own
    // dependency is a branch reference to a forked mlx-swift-lm that no
    // longer exists.
    .package(url: "https://github.com/DePasqualeOrg/swift-huggingface-mlx.git", branch: "main"),
    .package(url: "https://github.com/huggingface/swift-transformers.git", from: "0.1.0"),
  ],
  targets: [
    .target(
      name: "OperonMLX",
      dependencies: [
        .product(name: "OperonKit", package: "swift"),
        .product(name: "MLXLLM", package: "mlx-swift-lm"),
        .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        .product(name: "MLXLMHuggingFace", package: "swift-huggingface-mlx"),
        // At the resolved 0.1.x line, swift-transformers exposes only the
        // bundled "Transformers" product (targets: Tokenizers, Generation,
        // Models) — the standalone "Tokenizers" product was added later on
        // its default branch. `import Tokenizers` still works: depending on
        // a product gives access to each underlying target module by name.
        .product(name: "Transformers", package: "swift-transformers"),
      ]
    )
  ]
)
