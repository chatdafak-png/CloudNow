// swift-tools-version: 6.0

import Foundation
import PackageDescription

let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let nativeLibraries = "Binaries/NativeTransportLibraries.xcframework"
let hasNativeRuntime = FileManager.default.fileExists(atPath: packageDirectory.appendingPathComponent(nativeLibraries + "/Info.plist").path)
let nativeTargets: [Target] = hasNativeRuntime ? [
    .binaryTarget(name: "NativeTransportLibraries", path: nativeLibraries),
] : []

let package = Package(
    name: "NativeNVST",
    platforms: [.tvOS("26.2")],
    products: [.library(name: "NativeNVST", targets: ["NativeNVST"])],
    targets: [
        .target(
            name: "NativeNVST",
            dependencies: hasNativeRuntime ? ["NativeTransportLibraries"] : [],
            path: ".",
            exclude: hasNativeRuntime ? ["LICENSE", "UPSTREAM.md", "Binaries"] : ["LICENSE", "UPSTREAM.md", "Runtime"],
            sources: hasNativeRuntime ? ["Sources/NativeNVST", "Runtime"] : ["Sources/NativeNVST"]
        ),
    ] + nativeTargets,
    swiftLanguageModes: [.v5]
)
