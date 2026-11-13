// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "TriTab",
    platforms: [.macOS(.v13)],
    dependencies: [
        // 自動アップデート
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        // 非公開の MultitouchSupport.framework を dlopen で読む薄い C ブリッジ
        .target(name: "MTBridge"),
        // ジェスチャー判定・アプリ別キー対応表など、UI に依存しないロジック
        .target(name: "TriTabCore"),
        // メニューバー常駐アプリ本体（常駐部分は AppKit。設定画面・案内は別プロセスの SwiftUI）
        .executableTarget(
            name: "TriTab",
            dependencies: ["MTBridge", "TriTabCore", .product(name: "Sparkle", package: "Sparkle")],
            // .app の中では Sparkle.framework を Contents/Frameworks に置く
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "TriTabCoreTests", dependencies: ["TriTabCore"]),
    ]
)
