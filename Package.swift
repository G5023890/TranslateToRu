// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TranslatorHotkey",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "TranslatorHotkey"
        )
    ]
)
