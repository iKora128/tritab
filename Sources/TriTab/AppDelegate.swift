import AppKit
import QuickLookUI
import Sparkle
import TriTabCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = Settings.shared
    private let touch = MultitouchManager.shared
    private let input = InputTap.shared
    private let shelf = ShelfController.shared
    /// TRITAB_DRY_RUN=1 なら、検出だけしてキーは送らない（動作確認用）
    private let dryRun = ProcessInfo.processInfo.environment["TRITAB_DRY_RUN"] != nil
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var tapRetryTimer: Timer?
    /// App Nap を止めておく（しばらく操作がないと処理が後回しにされ、最初のスワイプだけ遅れるため）
    private var activity: NSObjectProtocol?
    private var appliedConfig: GestureEngine.Config?
    private var appliedFingers: Int?
    private var shelfEnabled = false
    /// 自動アップデート（Sparkle）。更新情報の場所と公開鍵は Info.plist の SUFeedURL / SUPublicEDKey
    private var updater: SPUStandardUpdaterController!
    /// 見つかったけれど、まだ見てもらっていない新しい版。メニューの先頭で控えめに知らせる
    private var pendingUpdate: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Migration.runIfNeeded()
        updater = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self)
        // .app として起動したときだけ動かす（swift run などで直接起動すると Info.plist の設定がないため）
        if Bundle.main.bundleURL.pathExtension == "app" { updater.startUpdater() }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "トラックパッドのジェスチャーにすぐ反応するため")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = MenuBarIcon.make()
        }
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        touch.onGesture = { [weak self] event in self?.handle(event) }
        touch.log("起動: アクセシビリティ許可=\(KeySender.isTrusted) bundle=\(Bundle.main.bundleIdentifier ?? "-") dryRun=\(dryRun)")
        if !touch.start() {
            showAlert(title: L("トラックパッドを読み取れませんでした", "Couldn't Read the Trackpad"),
                      message: L("MultitouchSupport.framework を読み込めませんでした。macOS のバージョンを確認してください。",
                                 "MultitouchSupport.framework couldn't be loaded. Please check your macOS version."))
        }

        input.decideClick = { [weak self] in self?.decideClick() ?? .passThrough }
        input.shouldSuppressScroll = { [weak self] in self?.touch.shouldSuppressScroll ?? false }
        input.onKeyDown = { [weak self] event in self?.shelf.handleKeyDown(event) ?? false }
        startInputTap()

        applySettings()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                               queue: .main) { [weak self] _ in self?.applySettings() }
        // 設定画面から「棚のアニメーションを試す」
        DistributedNotificationCenter.default().addObserver(forName: ShelfPreview.name, object: nil,
                                                            queue: .main) { [weak self] note in
            let style = (note.userInfo?["style"] as? String).flatMap(ShelfAnimationStyle.init(rawValue:))
            self?.shelf.preview(style)
        }
        if ProcessInfo.processInfo.environment["TRITAB_DEBUG"] != nil {
            // 動作確認用（記録モードのときだけ）: 棚にファイルを入れる / 開く / Quick Look / 閉じる
            DistributedNotificationCenter.default().addObserver(forName: Notification.Name("io.github.ikora128.TriTab.debugShelf"),
                                                                object: nil, queue: .main) { [weak self] note in
                guard let self, let cmd = note.userInfo?["cmd"] as? String else { return }
                switch cmd {
                case "add": self.shelf.add((note.userInfo?["paths"] as? [String] ?? []).map(URL.init(fileURLWithPath:)))
                case "open": self.shelf.show(.open)
                case "large": self.shelf.show(.large)
                case "close": self.shelf.show(self.shelf.items.isEmpty ? .hidden : .collapsed)
                case "quicklook": self.shelf.showQuickLook()
                case "qlclose": QLPreviewPanel.shared()?.orderOut(nil)
                case "clear": self.shelf.removeAll()
                default: break
                }
            }
        }
        // 設定画面（別プロセス）で変更されたら読み直す
        DistributedNotificationCenter.default().addObserver(forName: SettingsProcess.changedNotification, object: nil,
                                                            queue: .main) { [weak self] _ in
            UserDefaults.standard.synchronize()
            self?.applySettings()
        }

        if !settings.didOnboard {
            settings.didOnboard = true
            SettingsProcess.open(.onboarding)
        } else if !KeySender.isTrusted {
            // 更新で許可が外れた場合などに、もう一度許可を求める
            KeySender.requestTrust()
        }
    }

    /// イベントタップはアクセシビリティ許可がないと作れない。許可されるまで数秒おきに試す
    private func startInputTap() {
        if input.start() {
            tapRetryTimer?.invalidate()
            tapRetryTimer = nil
            touch.log("イベントタップ開始")
            return
        }
        guard tapRetryTimer == nil else { return }
        tapRetryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.startInputTap()
        }
    }

    // MARK: - ジェスチャー → 動作

    private var n: Int { settings.fingers }

    private func handle(_ event: GestureEvent) {
        guard settings.enabled else { return }
        // はじめての案内の「試してみよう」に知らせる
        GestureBroadcast.post(event)
        // TriTab 自身の画面（設定・案内）が前面のときは何もしない（⌘W で閉じてしまわないように）
        if frontmostBundleID == Bundle.main.bundleIdentifier { return }
        touch.log("ジェスチャー \(event) frontmost=\(frontmostBundleID ?? "nil")")
        switch event {
        case let .swipe(direction, fingers) where fingers == n:
            perform(settings.mapping.action(for: direction))
        case .swipe(.up, 5) where settings.fiveFingerSleep:
            sleepDisplay()
        case .tap(let fingers) where fingers == n && settings.tapNewTab:
            perform(.newTab)
        case .tap(let fingers) where fingers == n + 1 && settings.imeTap:
            IMESwitcher.toggle()
            feedback(IMESwitcher.currentIsASCII ? L("あ  かな", "あ  Kana") : L("A  英数", "A  Eisu"))
        case .pinchIn(3) where settings.pinchReload:
            perform(.reload)
        default:
            break
        }
    }

    /// 押し込みクリックの瞬間に呼ばれる（イベントタップ経由）
    private func decideClick() -> InputTap.ClickDecision {
        let fingers = touch.intentionalClickFingers
        touch.noteClick()
        guard settings.enabled, !dryRun else { return .passThrough }
        if fingers == n, settings.clickCmd {
            return .addCommand
        }
        if fingers == n + 1, settings.clickReopen {
            return .replace { [weak self] in self?.perform(.reopenTab) }
        }
        return .passThrough
    }

    private var frontmostBundleID: String? { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }

    private func perform(_ action: TabAction) {
        guard action != .none else { return }
        let bundleID = frontmostBundleID
        if bundleID == Bundle.main.bundleIdentifier { return } // 自分の画面では何もしない
        let profile = AppProfiles.profile(for: bundleID) ?? (settings.allApps ? AppProfile.generic : nil)
        guard let profile, let combo = profile.combo(for: action) else {
            touch.log("\(bundleID ?? "?") では \(action.rawValue) を送りません")
            hud(L("このアプリでは無効", "Disabled in this app"))
            return
        }
        guard KeySender.isTrusted else {
            touch.log("アクセシビリティ未許可のため送信できません")
            hud(L("アクセシビリティを許可してください", "Please allow Accessibility access"))
            return
        }
        if dryRun {
            touch.log("dry-run: \(action.rawValue) を送るはず")
            hud(L("検出: \(action.hudText)", "Detected: \(action.hudText)"))
            return
        }
        KeySender.send(combo)
        touch.log("\(bundleID ?? "?") に \(action.rawValue) を送信 (keyCode=\(combo.keyCode))")
        feedback(action.hudText)
    }

    /// 振動 + 画面表示
    private func feedback(_ text: String) {
        if settings.haptic {
            // 発火した瞬間に「コッ」と返す。どこで決まったかが指でわかる
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        hud(text)
    }

    private func hud(_ text: String) {
        if settings.showHUD { HUD.shared.show(text) }
    }

    private func sleepDisplay() {
        guard !dryRun else { hud(L("検出: ディスプレイをスリープ", "Detected: Sleep Display")); return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["displaysleepnow"]
        try? p.run()
    }

    // MARK: - メニュー

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if let pendingUpdate {
            menu.addItem(item(L("TriTab \(pendingUpdate) にアップデート…", "Update to TriTab \(pendingUpdate)…")) { [unowned self] in
                checkForUpdates()
            })
            menu.addItem(.separator())
        }

        menu.addItem(item(L("TriTab を有効にする", "Enable TriTab"), checked: settings.enabled) { [unowned self] in
            settings.enabled.toggle()
        })

        // 警告（あるときだけ）
        var warnings: [NSMenuItem] = []
        if !KeySender.isTrusted {
            warnings.append(item(L("⚠︎ アクセシビリティの許可が必要です…", "⚠︎ Accessibility Access Required…")) {
                KeySender.requestTrust()
            })
        }
        let conflicts = SystemGestureChecker.conflicts(fingers: settings.fingers)
        if !conflicts.isEmpty {
            warnings.append(item(L("⚠︎ macOS のジェスチャーと競合しています（\(conflicts.count)件）…",
                                   "⚠︎ Conflicts with macOS Gestures (\(conflicts.count))…")) { [unowned self] in
                showConflicts(conflicts)
            })
        }
        if !NSRunningApplication.runningApplications(withBundleIdentifier: "com.hegenberg.BetterTouchTool").isEmpty {
            warnings.append(disabled(L("⚠︎ BetterTouchTool が起動中です（同じジェスチャーが二重に動く可能性）",
                                       "⚠︎ BetterTouchTool is running (gestures may fire twice)")))
        }
        if touch.isLoaded && touch.deviceCount == 0 {
            warnings.append(disabled(L("⚠︎ トラックパッドが見つかりません", "⚠︎ No Trackpad Found")))
        }
        if !warnings.isEmpty {
            menu.addItem(.separator())
            warnings.forEach(menu.addItem)
        }

        menu.addItem(.separator())
        let prefs = item(L("設定…", "Settings…")) { SettingsProcess.open(.settings) }
        prefs.keyEquivalent = ","
        menu.addItem(prefs)
        menu.addItem(item(L("アップデートを確認…", "Check for Updates…")) { [unowned self] in checkForUpdates() })
        menu.addItem(.separator())
        menu.addItem(item(L("TriTab を終了", "Quit TriTab")) { NSApp.terminate(nil) })
    }

    /// 更新を確認する。新しい版がすでに見つかっていれば、その画面を前に出す
    private func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        updater.checkForUpdates(nil)
    }

    /// 設定（UserDefaults）を各機能に反映する。設定画面・メニューのどちらから変えても、ここを通る
    private func applySettings() {
        updateIcon()
        updateScrollSuppression()
        let config = settings.engineConfig
        if config != appliedConfig {
            appliedConfig = config
            touch.update(config: config)
        }
        input.imeCommandEnabled = settings.imeCommandActive
        shelf.style = settings.shelfAnimation
        if settings.shelf != shelfEnabled {
            shelfEnabled = settings.shelf
            shelf.setEnabled(shelfEnabled)
        }
        if settings.fingers != appliedFingers {
            let first = appliedFingers == nil
            appliedFingers = settings.fingers
            // 指の本数を変えたら、その本数で macOS と競合していないか確認する
            if !first {
                let conflicts = SystemGestureChecker.conflicts(fingers: settings.fingers)
                if !conflicts.isEmpty { DispatchQueue.main.async { self.showConflicts(conflicts) } }
            }
        }
    }

    /// N 本以上の指が触れている間はスクロールを止める（TriTab が無効なら止めない）
    private func updateScrollSuppression() {
        touch.scrollSuppressFingers = settings.enabled ? settings.fingers : 0
    }

    private func setFingers(_ count: Int) {
        settings.fingers = count // applySettings が競合を確認する
    }

    private func updateIcon() {
        statusItem.button?.appearsDisabled = !settings.enabled
    }

    // MARK: - ダイアログ

    private func showConflicts(_ conflicts: [GestureConflict]) {
        let n = settings.fingers
        let lines = conflicts.map { L("・\($0.title)\n　→ \($0.fix)", "• \($0.title)\n   → \($0.fix)") }.joined(separator: "\n\n")
        let alert = NSAlert()
        alert.messageText = L("macOS の\(n)本指ジェスチャーと競合しています", "Conflicts with macOS \(n)-Finger Gestures")
        alert.informativeText = L("""
        macOS 側のジェスチャーも同時に動いてしまうため、次の設定を変更してください。

        \(lines)

        場所：システム設定 › トラックパッド › その他のジェスチャ
        """, """
        The macOS gestures would fire at the same time as TriTab's, so please change these settings:

        \(lines)

        Location: System Settings › Trackpad › More Gestures
        """)
        alert.addButton(withTitle: L("トラックパッド設定を開く", "Open Trackpad Settings"))
        let suggestsFour = settings.fingers == 3 && conflicts.contains { $0.suggestsFourFingerMode }
        if suggestsFour { alert.addButton(withTitle: L("4本指モードにする", "Use 4-Finger Mode")) }
        alert.addButton(withTitle: L("あとで", "Not Now"))

        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            SystemGestureChecker.openTrackpadSettings()
        case .alertSecondButtonReturn where suggestsFour:
            setFingers(4)
        default:
            break
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - メニュー項目ヘルパー

    private func item(_ title: String, checked: Bool = false, action: @escaping () -> Void) -> NSMenuItem {
        let i = ClosureMenuItem(title: title, handler: action)
        i.state = checked ? .on : .off
        return i
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        items.forEach(sub.addItem)
        parent.submenu = sub
        return parent
    }
}

private extension Settings {
    /// ⌘ 英かなは、TriTab 全体が有効なときだけ動かす
    var imeCommandActive: Bool { enabled && imeCmd }
}

// MARK: - 自動アップデートの知らせ方
//
// TriTab はメニューバーに常駐していて前面に出ないので、定期確認で新しい版が見つかっても、
// いきなり更新の画面を前に出さない。起動直後など「いま見せてよい」ときだけ Sparkle に画面を出してもらい、
// それ以外はメニューの先頭に「TriTab x.y.z にアップデート…」を出して、押されたら画面を出す。
// https://sparkle-project.org/documentation/gentle-reminders
extension AppDelegate: SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        if !handleShowingUpdate { pendingUpdate = update.displayVersionString }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        pendingUpdate = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        pendingUpdate = nil
    }
}

/// クロージャで動くメニュー項目
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}
