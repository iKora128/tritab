import CoreGraphics

/// ユーザーがジェスチャーに割り当てる「動作」。キーそのものではなく意味を持たせ、
/// アプリごとの違い（Arc は ⌘⌥↓ など）は `AppProfile` 側で吸収する。
public enum TabAction: String, CaseIterable, Sendable {
    case nextTab, prevTab, closeTab, reopenTab, newTab, reload, none

    public var label: String {
        switch self {
        case .nextTab: return L("次のタブ", "Next Tab")
        case .prevTab: return L("前のタブ", "Previous Tab")
        case .closeTab: return L("タブを閉じる", "Close Tab")
        case .reopenTab: return L("閉じたタブを復元", "Reopen Closed Tab")
        case .newTab: return L("新しいタブ", "New Tab")
        case .reload: return L("再読み込み", "Reload")
        case .none: return L("なし", "None")
        }
    }

    /// HUD 表示用
    public var hudText: String {
        switch self {
        case .nextTab: return L("次のタブ  ›", "Next Tab  ›")
        case .prevTab: return L("‹  前のタブ", "‹  Previous Tab")
        case .closeTab: return L("×  タブを閉じる", "×  Close Tab")
        case .reopenTab: return L("↺  閉じたタブを復元", "↺  Reopen Closed Tab")
        case .newTab: return L("+  新しいタブ", "+  New Tab")
        case .reload: return L("⟳  再読み込み", "⟳  Reload")
        case .none: return ""
        }
    }
}

public struct KeyCombo: Equatable, Sendable {
    public var keyCode: CGKeyCode
    public var flags: CGEventFlags

    public init(_ keyCode: CGKeyCode, _ flags: CGEventFlags) {
        self.keyCode = keyCode
        self.flags = flags
    }

    // 仮想キーコード（ANSI 位置）。Tab と矢印はキーボード配列に依存しない。
    // W / T は QWERTY 系（US・JIS とも同じ位置）を前提にしている。
    static let kTab: CGKeyCode = 48
    static let kW: CGKeyCode = 13
    static let kT: CGKeyCode = 17
    static let kR: CGKeyCode = 15
    static let kLeft: CGKeyCode = 123
    static let kRight: CGKeyCode = 124
    static let kDown: CGKeyCode = 125
    static let kUp: CGKeyCode = 126

    public static let ctrlTab = KeyCombo(kTab, .maskControl)
    public static let ctrlShiftTab = KeyCombo(kTab, [.maskControl, .maskShift])
    public static let cmdW = KeyCombo(kW, .maskCommand)
    public static let cmdT = KeyCombo(kT, .maskCommand)
    public static let cmdShiftT = KeyCombo(kT, [.maskCommand, .maskShift])
    public static let cmdR = KeyCombo(kR, .maskCommand)
    public static let cmdOptRight = KeyCombo(kRight, [.maskCommand, .maskAlternate])
    public static let cmdOptLeft = KeyCombo(kLeft, [.maskCommand, .maskAlternate])
    public static let cmdOptDown = KeyCombo(kDown, [.maskCommand, .maskAlternate])
    public static let cmdOptUp = KeyCombo(kUp, [.maskCommand, .maskAlternate])

    public var isArrow: Bool { (123...126).contains(keyCode) }
}

/// アプリごとの「動作 → キー」対応。nil の動作はそのアプリでは何もしない（誤爆防止）。
public struct AppProfile: Equatable, Sendable {
    public var name: String
    public var next: KeyCombo?
    public var prev: KeyCombo?
    public var close: KeyCombo?
    public var reopen: KeyCombo?
    public var new: KeyCombo?
    public var reload: KeyCombo?

    public init(name: String, next: KeyCombo?, prev: KeyCombo?, close: KeyCombo?, reopen: KeyCombo?,
                new: KeyCombo?, reload: KeyCombo? = nil) {
        self.name = name
        self.next = next
        self.prev = prev
        self.close = close
        self.reopen = reopen
        self.new = new
        self.reload = reload
    }

    /// 何もしないアプリ用
    static func disabled(_ name: String) -> AppProfile {
        AppProfile(name: name, next: nil, prev: nil, close: nil, reopen: nil, new: nil)
    }

    public func combo(for action: TabAction) -> KeyCombo? {
        switch action {
        case .nextTab: return next
        case .prevTab: return prev
        case .closeTab: return close
        case .reopenTab: return reopen
        case .newTab: return new
        case .reload: return reload
        case .none: return nil
        }
    }

    // MARK: - 種類別テンプレート

    /// Safari / Chromium 系: ⌃Tab は並び順どおりに移動する
    static func browser(_ name: String) -> AppProfile {
        AppProfile(name: name, next: .ctrlTab, prev: .ctrlShiftTab, close: .cmdW, reopen: .cmdShiftT, new: .cmdT, reload: .cmdR)
    }

    /// Firefox 系: ⌃Tab が「最近使った順」になる設定があるので ⌘⌥←/→ を使う
    static func firefox(_ name: String) -> AppProfile {
        AppProfile(name: name, next: .cmdOptRight, prev: .cmdOptLeft, close: .cmdW, reopen: .cmdShiftT, new: .cmdT, reload: .cmdR)
    }

    /// Arc: ⌃Tab は最近使った順。縦タブなので ⌘⌥↓/↑ が並び順の移動
    static func arc(_ name: String) -> AppProfile {
        AppProfile(name: name, next: .cmdOptDown, prev: .cmdOptUp, close: .cmdW, reopen: .cmdShiftT, new: .cmdT, reload: .cmdR)
    }

    /// VS Code 系: ⌃Tab は最近使った順のピッカーなので ⌘⌥←/→（Open Next/Previous Editor）
    static func editor(_ name: String) -> AppProfile {
        AppProfile(name: name, next: .cmdOptRight, prev: .cmdOptLeft, close: .cmdW, reopen: .cmdShiftT, new: nil)
    }

    /// ターミナル: ⌘W は実行中のプロセスごと閉じるので「閉じる」は無効。⇧⌘T も別機能なので無効
    static func terminal(_ name: String) -> AppProfile {
        AppProfile(name: name, next: .ctrlTab, prev: .ctrlShiftTab, close: nil, reopen: nil, new: .cmdT)
    }

    /// 対応表にないアプリ用（「対応アプリ以外でも動かす」を ON にしたときだけ使う）
    public static let generic = AppProfile(name: L("その他のアプリ", "Other Apps"), next: .ctrlTab, prev: .ctrlShiftTab,
                                           close: .cmdW, reopen: .cmdShiftT, new: .cmdT, reload: .cmdR)
}

public enum AppProfiles {
    /// bundle ID → プロファイル。載っていないアプリは「未登録のアプリでも動かす」が ON なら汎用キーを送る。
    public static let all: [String: AppProfile] = {
        var m: [String: AppProfile] = [:]
        func add(_ ids: [String], _ p: AppProfile) { for id in ids { m[id] = p } }

        add(["com.apple.Safari", "com.apple.SafariTechnologyPreview"], .browser("Safari"))
        add(["com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary"], .browser("Google Chrome"))
        add(["org.chromium.Chromium"], .browser("Chromium"))
        add(["com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev"], .browser("Microsoft Edge"))
        add(["com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly"], .browser("Brave"))
        add(["com.vivaldi.Vivaldi"], .browser("Vivaldi"))
        add(["com.operasoftware.Opera"], .browser("Opera"))
        add(["company.thebrowser.dia"], .browser("Dia"))
        add(["com.kagi.kagimacOS"], .browser("Orion"))
        add(["company.thebrowser.Browser"], .arc("Arc"))
        add(["org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly"], .firefox("Firefox"))
        add(["app.zen-browser.zen"], .firefox("Zen"))
        add(["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"], .editor("Visual Studio Code"))
        add(["com.todesktop.230313mzl4w4u92"], .editor("Cursor"))
        add(["com.exafunction.windsurf"], .editor("Windsurf"))
        add(["com.apple.Terminal"], .terminal(L("ターミナル", "Terminal")))
        add(["com.googlecode.iterm2"], .terminal("iTerm2"))
        add(["com.mitchellh.ghostty"], .terminal("Ghostty"))
        // Warp は ⇧⌘T で閉じたタブを復元できる（60 秒以内）
        var warp = AppProfile.terminal("Warp"); warp.reopen = .cmdShiftT
        add(["dev.warp.Warp-Stable"], warp)
        // タブのないチャットアプリ: ⌘W はウィンドウを閉じ、⇧⌘T は別機能（Slack はスレッド画面）なので何もしない
        add(["com.tinyspeck.slackmacgap"], .disabled(L("Slack（無効）", "Slack (disabled)")))
        add(["com.hnc.Discord"], .disabled(L("Discord（無効）", "Discord (disabled)")))
        // メール: ⌘R は返信、⌘W はメッセージを閉じる
        add(["com.apple.mail"], .disabled(L("メール（無効）", "Mail (disabled)")))
        // Finder: 閉じたタブの復元はない
        add(["com.apple.finder"], AppProfile(name: "Finder", next: .ctrlTab, prev: .ctrlShiftTab, close: .cmdW, reopen: nil, new: .cmdT))
        return m
    }()

    public static func profile(for bundleID: String?) -> AppProfile? {
        guard let bundleID else { return nil }
        return all[bundleID]
    }

    /// メニュー表示用の対応アプリ名（重複なし・並び順固定）
    public static var supportedAppNames: [String] {
        Array(Set(all.values.map(\.name))).sorted()
    }
}

/// ジェスチャーの方向 → 動作。ユーザー設定から組み立てる。
public struct GestureMapping: Equatable, Sendable {
    /// true: 左スワイプで次（右）のタブ（日本の BTT 設定記事で多数派）
    public var leftIsNext: Bool
    public var up: TabAction
    public var down: TabAction

    public init(leftIsNext: Bool = true, up: TabAction = .reopenTab, down: TabAction = .closeTab) {
        self.leftIsNext = leftIsNext
        self.up = up
        self.down = down
    }

    public func action(for direction: SwipeDirection) -> TabAction {
        switch direction {
        case .left: return leftIsNext ? .nextTab : .prevTab
        case .right: return leftIsNext ? .prevTab : .nextTab
        case .up: return up
        case .down: return down
        }
    }
}
