// swift-tools-version: 6.0

import Foundation
import PackageDescription

let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let hasNativeRuntime = FileManager.default.fileExists(atPath: packageDirectory.appendingPathComponent("Binaries/OpenSSL.xcframework/Info.plist").path)
    && FileManager.default.fileExists(atPath: packageDirectory.appendingPathComponent("Binaries/usrsctp.xcframework/Info.plist").path)
let nativeTargets: [Target] = hasNativeRuntime ? [
    .binaryTarget(name: "OpenSSL", path: "Binaries/OpenSSL.xcframework"),
    .binaryTarget(name: "usrsctp", path: "Binaries/usrsctp.xcframework"),
] : []

let package = Package(
    name: "NativeNVST",
    platforms: [.tvOS("26.2")],
    products: [.library(name: "NativeNVST", targets: ["NativeNVST"])],
    targets: [
        .target(
            name: "NativeNVST",
            dependencies: hasNativeRuntime ? ["OpenSSL", "usrsctp"] : [],
            path: ".",
            exclude: hasNativeRuntime ? ["LICENSE", "UPSTREAM.md", "Binaries"] : ["LICENSE", "UPSTREAM.md", "Runtime"],
            sources: hasNativeRuntime ? ["Sources/NativeNVST", "Runtime"] : ["Sources/NativeNVST"]
        ),
    ] + nativeTargets,
    swiftLanguageModes: [.v5]
)
