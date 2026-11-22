// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "NativeNVST",
    platforms: [.tvOS("26.2")],
    products: [.library(name: "NativeNVST", targets: ["NativeNVST"])],
    targets: [.target(name: "NativeNVST")],
    swiftLanguageModes: [.v5]
)
