import AppKit
import SwiftUI

/// 設定画面・はじめての案内を表示する別プロセス（同じ実行ファイルを引数付きで起動する）。
///
/// SwiftUI は一度読み込むと、ウィンドウを閉じてもメモリ（約 25MB）を手放さない。
/// 常駐プロセスを 11MB 前後に保つため、画面は別プロセスで開き、閉じたら終了する。
/// 値は同じ UserDefaults（同じバンドル ID）に書き、変更を分散通知で常駐側に知らせる。
final class SettingsProcess: NSObject, NSApplicationDelegate, NSWindowDelegate {
    enum Mode: String {
        case settings = "--settings"
        case onboarding = "--onboarding"
    }

    static let changedNotification = Notification.Name("io.github.ikora128.TriTab.settingsChanged")

    /// 起動引数から、このプロセスが画面用かどうかを判定する
    static var launchMode: Mode? {
        CommandLine.arguments.lazy.compactMap(Mode.init(rawValue:)).first
    }

    /// 画面用プロセスとして動いているときの自分自身
    private static weak var current: SettingsProcess?

    /// 画面を開く。画面用プロセスの中から呼ばれたら、その場で切り替える。
    /// 常駐側から呼ばれたら、すでに開いている画面用プロセスを前に出すか、新しく起動する。
    static func open(_ mode: Mode) {
        if let current {
            current.show(mode)
            return
        }
        let me = ProcessInfo.processInfo.processIdentifier
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .first(where: { $0.processIdentifier != me }) {
            running.activate()
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.arguments = [mode.rawValue]
        config.activates = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config)
    }

    private let initialMode: Mode
    private var window: NSWindow?

    init(mode: Mode) {
        initialMode = mode
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.current = self
        _ = Settings.shared // 既定値を登録（日本語入力の有無で変わる値があるので、常駐側と同じにする）
        buildMainMenu()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                               queue: .main) { _ in
            DistributedNotificationCenter.default().postNotificationName(
                Self.changedNotification, object: nil, userInfo: nil, deliverImmediately: true)
        }
        show(initialMode)
    }

    private func show(_ mode: Mode) {
        // 前のウィンドウは閉じても終了しないよう、delegate を外してから閉じる
        if let old = window {
            old.delegate = nil
            old.close()
        }
        let w: NSWindow
        switch mode {
        case .settings:
            w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 580),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
            w.title = "TriTab 設定"
            w.toolbar = NSToolbar()
            w.toolbarStyle = .unified
            w.contentView = NSHostingView(rootView: SettingsView())
        case .onboarding:
            w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 540),
                         styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
            w.title = "TriTab へようこそ"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            w.contentView = NSHostingView(rootView: OnboardingView(onFinish: { [weak w] in w?.close() }))
        }
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }

    /// ⌘W / ⌘Q が効くように最小限のメニューを作る
    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "閉じる", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "ファイル")
        fileMenu.addItem(withTitle: "閉じる", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)
        NSApp.mainMenu = main
    }
}
