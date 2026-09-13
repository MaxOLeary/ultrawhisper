// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "UltraWhisper",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "UltraWhisper", targets: ["UltraWhisper"])
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.7", traits: [])
    ],
    targets: [
        .executableTarget(
            name: "UltraWhisper",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: ".",
            exclude: [
                "build.sh",
                "download-model.sh",
                "README.md",
                "SPEC.md",
                "eval",
                "icon",
                "UltraWhisper.app",
                "com.maxoleary.ultrawhisper.plist",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ApplicationServices"),
            ]
        )
    ]
)
