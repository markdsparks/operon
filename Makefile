.PHONY: check check-apple test test-python test-rust test-swift build-c-abi build-apple-xcframework verify-apple-xcframework build-swift-ios lint-rust lint-swift

check: test lint-rust

check-apple: check build-c-abi build-apple-xcframework verify-apple-xcframework test-swift build-swift-ios lint-swift

test: test-python test-rust

test-python:
	PYTHONPATH=sdk/python/src python3 -m unittest discover -s sdk/python/tests -v

test-rust:
	cargo test --workspace

build-c-abi:
	cargo build --release -p operon-core

build-apple-xcframework:
	scripts/build-apple-xcframework.sh

verify-apple-xcframework:
	scripts/verify-apple-xcframework.sh

test-swift:
	xcrun swift test --package-path sdk/swift

build-swift-ios:
	cd sdk/swift && xcodebuild -quiet -scheme OperonFoundationModels -destination 'generic/platform=iOS Simulator' build

lint-rust:
	cargo fmt --all -- --check
	cargo clippy --workspace --all-targets -- -D warnings

lint-swift:
	xcrun swift-format lint --recursive sdk/swift/Sources sdk/swift/Tests sdk/swift/Package.swift
