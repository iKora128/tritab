import AppKit

let app = NSApplication.shared

if let mode = SettingsProcess.launchMode {
    // 設定画面・はじめての案内だけの別プロセス。閉じたら終了する（SwiftUI のメモリを常駐側に残さないため）
    let delegate = SettingsProcess(mode: mode)
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
} else {
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory) // Dock に出さない（Info.plist の LSUIElement と同じ）
    app.run()
}
