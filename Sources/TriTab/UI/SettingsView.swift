import AppKit
import ServiceManagement
import SwiftUI
import TriTabCore

/// 設定画面（システム設定風のサイドバー）
struct SettingsView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case swipe, tapClick, input, shelf, apps, general
        var id: String { rawValue }

        var title: String {
            switch self {
            case .swipe: return "スワイプ"
            case .tapClick: return "タップとクリック"
            case .input: return "日本語入力"
            case .shelf: return "ノッチの棚"
            case .apps: return "対象アプリ"
            case .general: return "一般"
            }
        }

        var symbol: String {
            switch self {
            case .swipe: return "hand.draw.fill"
            case .tapClick: return "hand.tap.fill"
            case .input: return "character.bubble.fill"
            case .shelf: return "tray.full.fill"
            case .apps: return "square.grid.2x2.fill"
            case .general: return "gearshape.fill"
            }
        }

        /// 影の色
        var color: Color {
            switch self {
            case .swipe: return Sunset.rose
            case .tapClick: return Sunset.pink
            case .input: return Sunset.fuchsia
            case .shelf: return Sunset.purple
            case .apps: return Sunset.violet
            case .general: return .gray
            }
        }

        /// アイコンの塗り（ローズ → すみれ の同系色）
        var fill: LinearGradient? {
            switch self {
            case .swipe: return Sunset.badge(0)
            case .tapClick: return Sunset.badge(1)
            case .input: return Sunset.badge(2)
            case .shelf: return Sunset.badge(3)
            case .apps: return Sunset.badge(4)
            case .general: return nil
            }
        }
    }

    @State private var selection: Pane? = .swipe
    @AppStorage("enabled") private var enabled = true

    var body: some View {
        NavigationSplitView {
            // 選択中の項目を夕焼けのグラデーションにするため、サイドバーは自前で描く
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 10) {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .frame(width: 38, height: 38)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("TriTab").font(.headline)
                            Text(enabled ? "動作中" : "停止中")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(enabled ? Color.green : Color.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $enabled).labelsHidden().scaleEffect(0.85)
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 12)
                    ForEach(Pane.allCases) { pane in
                        SidebarRow(pane: pane, selected: (selection ?? .swipe) == pane)
                            .onTapGesture { selection = pane }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 220)
        } detail: {
            Group {
                switch selection ?? .swipe {
                case .swipe: SwipePane()
                case .tapClick: TapClickPane()
                case .input: InputPane()
                case .shelf: ShelfPane()
                case .apps: AppsPane()
                case .general: GeneralPane()
                }
            }
            .frame(minWidth: 460)
        }
        .frame(minWidth: 720, minHeight: 560)
        .tint(Sunset.accent)
        .toggleStyle(SunsetToggleStyle())
    }
}

/// サイドバーの 1 行。選択中は夕焼けのグラデーション
private struct SidebarRow: View {
    let pane: SettingsView.Pane
    let selected: Bool
    @State private var hover = false

    var body: some View {
        HStack(spacing: 9) {
            IconBadge(symbol: pane.symbol, color: pane.color, size: 22, fill: pane.fill)
            Text(pane.title)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.white : Color.primary)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? AnyShapeStyle(Sunset.gradient)
                               : AnyShapeStyle(Color.primary.opacity(hover ? 0.06 : 0)))
                .shadow(color: selected ? Sunset.fuchsia.opacity(0.3) : .clear, radius: 5, y: 2)
        )
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: selected)
    }
}

private extension View {
    /// macOS 14 以降だけで選択不可にする
    @ViewBuilder func selectionDisabled() -> some View {
        if #available(macOS 14.0, *) {
            self.selectionDisabled(true)
        } else {
            self
        }
    }
}

// MARK: - スワイプ

private struct SwipePane: View {
    @AppStorage("fingers") private var fingers = 3
    @AppStorage("leftIsNext") private var leftIsNext = true
    @AppStorage("upAction") private var upAction: TabAction = .reopenTab
    @AppStorage("downAction") private var downAction: TabAction = .closeTab
    @AppStorage("sensitivity") private var sensitivity: Sensitivity = .low
    @AppStorage("swipeReverse") private var swipeReverse = true

    var body: some View {
        Form {
            Section {
                PaneHeader(symbol: "hand.draw.fill", color: Sunset.rose, fill: Sunset.badge(0), title: "スワイプでタブを操作",
                           subtitle: "\(fingers)本指で払うと、1回につき1つだけ動きます。")
            }
            Section("ジェスチャー") {
                GestureRow(kind: .swipe(.left, fingers: fingers), title: "左へスワイプ") {
                    Text(leftIsNext ? "次のタブ" : "前のタブ").foregroundStyle(.secondary)
                }
                GestureRow(kind: .swipe(.right, fingers: fingers), title: "右へスワイプ") {
                    Text(leftIsNext ? "前のタブ" : "次のタブ").foregroundStyle(.secondary)
                }
                GestureRow(kind: .swipe(.up, fingers: fingers), title: "上へスワイプ") {
                    Picker("", selection: $upAction) {
                        ForEach([TabAction.reopenTab, .newTab, .none], id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                GestureRow(kind: .swipe(.down, fingers: fingers), title: "下へスワイプ") {
                    Picker("", selection: $downAction) {
                        ForEach([TabAction.closeTab, .none], id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
            Section {
                Picker("左右の向き", selection: $leftIsNext) {
                    Text("左へ払うと次（右）のタブ").tag(true)
                    Text("左へ払うと前（左）のタブ").tag(false)
                }
                Picker("指の本数", selection: $fingers) {
                    Text("3本指").tag(3)
                    Text("4本指").tag(4)
                }
                Picker("感度", selection: $sensitivity) {
                    ForEach(Sensitivity.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle(isOn: $swipeReverse) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("指を離さずに左右に往復")
                        Text("右へ払ったあと、そのまま左へ戻すともう一度移動します").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("「3本指のドラッグ」を使っている場合は 4本指にしてください。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - タップとクリック

private struct TapClickPane: View {
    @AppStorage("fingers") private var fingers = 3
    @AppStorage("tapNewTab") private var tapNewTab = true
    @AppStorage("clickCmd") private var clickCmd = true
    @AppStorage("clickReopen") private var clickReopen = true
    @AppStorage("pinchReload") private var pinchReload = true
    @AppStorage("fiveFingerSleep") private var fiveFingerSleep = false

    var body: some View {
        Form {
            Section {
                PaneHeader(symbol: "hand.tap.fill", color: Sunset.pink, fill: Sunset.badge(1), title: "タップ・クリック・つまむ",
                           subtitle: "リンクを新しいタブで開く、再読み込みなどをジェスチャーで。")
            }
            Section("タブ") {
                GestureRow(kind: .tap(fingers: fingers), title: "\(fingers)本指でタップ", detail: "新しいタブを開く") {
                    Toggle("", isOn: $tapNewTab).labelsHidden()
                }
                GestureRow(kind: .click(fingers: fingers), title: "\(fingers)本指でクリック",
                           detail: "⌘クリック（リンクを新しいタブで開く）") {
                    Toggle("", isOn: $clickCmd).labelsHidden()
                }
                GestureRow(kind: .click(fingers: fingers + 1), title: "\(fingers + 1)本指でクリック",
                           detail: "閉じたタブを復元") {
                    Toggle("", isOn: $clickReopen).labelsHidden()
                }
                GestureRow(kind: .pinch, title: "親指＋2本指でつまむ", detail: "再読み込み") {
                    Toggle("", isOn: $pinchReload).labelsHidden()
                }
            }
            Section("その他") {
                GestureRow(kind: .swipe(.up, fingers: 5), title: "5本指で上へスワイプ", detail: "ディスプレイをスリープ") {
                    Toggle("", isOn: $fiveFingerSleep).labelsHidden()
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 日本語入力

private struct InputPane: View {
    @AppStorage("fingers") private var fingers = 3
    @AppStorage("imeCmd") private var imeCmd = false
    @AppStorage("imeTap") private var imeTap = false

    var body: some View {
        Form {
            Section {
                PaneHeader(symbol: "character.bubble.fill", color: Sunset.fuchsia, fill: Sunset.badge(2), title: "英数／かなをすばやく切り替え",
                           subtitle: "Karabiner-Elements の定番設定と同じ操作を、TriTab だけで。")
            }
            Section {
                HStack(spacing: 12) {
                    KeyCap(text: "⌘", caption: "左")
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    Text("英数").font(.headline)
                    Spacer().frame(width: 24)
                    KeyCap(text: "⌘", caption: "右")
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    Text("かな").font(.headline)
                    Spacer()
                    Toggle("", isOn: $imeCmd).labelsHidden()
                }
                .padding(.vertical, 4)
            } header: {
                Text("⌘キーを単体で押す")
            } footer: {
                Text("⌘を押して、ほかのキーを押さずに離したときだけ切り替わります。⌘C などのショートカットはそのまま使えます。パスワード入力欄では macOS の制限で切り替わりません。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("トラックパッド") {
                GestureRow(kind: .tap(fingers: fingers + 1), title: "\(fingers + 1)本指でタップ",
                           detail: "英数 ⇄ かな を切り替え") {
                    Toggle("", isOn: $imeTap).labelsHidden()
                }
            }
            if FileManager.default.fileExists(atPath: "/Applications/Karabiner-Elements.app") {
                Section {
                    Label("Karabiner-Elements で同じルール（⌘単体で英数／かな）を使っている場合は、そちらをオフにしてください。",
                          systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct KeyCap: View {
    let text: String
    let caption: String

    var body: some View {
        VStack(spacing: 0) {
            Text(text).font(.system(size: 17, weight: .medium))
            Text(caption).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .frame(width: 40, height: 36)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.25), radius: 0.5, y: 1)
        )
    }
}

// MARK: - ノッチの棚

private struct ShelfPane: View {
    @AppStorage("shelf") private var shelf = false
    @AppStorage("shelfAnimation") private var animation: ShelfAnimationStyle = .jelly

    var body: some View {
        Form {
            Section {
                PaneHeader(symbol: "tray.full.fill", color: Sunset.purple, fill: Sunset.badge(3), title: "ノッチの棚",
                           subtitle: "ファイルや画像、テキストをノッチに一時置き。あとで好きな場所へ。")
            }
            Section {
                Toggle("ノッチの棚を使う", isOn: $shelf)
            }
            Section {
                Picker("動き", selection: $animation) {
                    ForEach(ShelfAnimationStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                HStack {
                    Button {
                        ShelfPreview.post(animation)
                    } label: {
                        Label("この動きを試す", systemImage: "play.fill")
                    }
                    .buttonStyle(SunsetButtonStyle())
                    Button {
                        ShelfPreview.post(nil)
                    } label: {
                        Label("全部の動きを順番に見る", systemImage: "play.square.stack")
                    }
                    Spacer()
                }
            } header: {
                Text("アニメーション")
            } footer: {
                Text("ボタンを押すと、画面上部のノッチで棚が実際に動きます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("使い方") {
                Step(number: 1, text: "ファイルをドラッグして少し上へ動かすと、ノッチから棚が顔を出す")
                Step(number: 2, text: "そのまま上へ持っていき、棚にドロップする")
                Step(number: 3, text: "ノッチにマウスを乗せても棚が開く。開いているあいだは ⌘V でクリップボードの中身を置ける")
                Step(number: 4, text: "棚のファイルを好きな場所へドラッグ。置いたら棚から消えます")
            }
        }
        .formStyle(.grouped)
    }
}

/// 設定画面 → 常駐側へ「棚のアニメーションを見せて」
enum ShelfPreview {
    static let name = Notification.Name("io.github.ikora128.TriTab.previewShelf")

    static func post(_ style: ShelfAnimationStyle?) {
        DistributedNotificationCenter.default().postNotificationName(
            name, object: nil, userInfo: style.map { ["style": $0.rawValue] }, deliverImmediately: true)
    }
}

private struct Step: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold)).foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.orange.gradient))
            Text(text)
        }
    }
}

// MARK: - 対象アプリ

private struct AppsPane: View {
    @AppStorage("allApps") private var allApps = true

    var body: some View {
        Form {
            Section {
                PaneHeader(symbol: "square.grid.2x2.fill", color: Sunset.violet, fill: Sunset.badge(4), title: "対象アプリ",
                           subtitle: "アプリごとにショートカットの違いを自動で切り替えます。")
            }
            Section {
                Toggle("登録のないアプリでも動かす", isOn: $allApps)
            } footer: {
                Text("オンにすると、登録のないアプリには ⌃Tab / ⌘W / ⇧⌘T を送ります。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("専用の設定があるアプリ") {
                ForEach(AppProfiles.supportedAppNames, id: \.self) { name in
                    Text(name)
                }
            }
            Section {
                Text("ターミナル系では「閉じる」「復元」を送りません（実行中の処理を閉じてしまわないように）。Slack・Discord・メールでは何もしません。")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 一般

private struct GeneralPane: View {
    @AppStorage("showHUD") private var showHUD = true
    @AppStorage("haptic") private var haptic = false
    @AppStorage("fingers") private var fingers = 3
    @State private var loginItem = SMAppService.mainApp.status == .enabled
    @State private var trusted = KeySender.isTrusted
    @State private var conflicts: [GestureConflict] = []
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                PaneHeader(symbol: "gearshape.fill", color: .gray, title: "一般",
                           subtitle: "起動、表示、許可の状態。")
            }
            Section("動作") {
                Toggle("ログイン時に起動", isOn: Binding(get: { loginItem }, set: setLoginItem))
                Toggle("操作した内容を画面に表示", isOn: $showHUD)
                Toggle("操作時にトラックパッドを振動（小さな音が鳴ります）", isOn: $haptic)
            }
            Section("状態") {
                LabeledContent("アクセシビリティ") {
                    if trusted {
                        StatusPill(ok: true, text: "許可済み")
                    } else {
                        Button("許可する…") { KeySender.requestTrust() }.buttonStyle(SunsetButtonStyle())
                    }
                }
                LabeledContent("macOS のジェスチャー") {
                    if conflicts.isEmpty {
                        StatusPill(ok: true, text: "競合なし")
                    } else {
                        Button("トラックパッド設定を開く…") { SystemGestureChecker.openTrackpadSettings() }
                            .buttonStyle(SunsetButtonStyle())
                    }
                }
                ForEach(conflicts, id: \.title) { c in
                    VStack(alignment: .leading, spacing: 2) {
                        Label(c.title, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(c.fix).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Button("はじめの案内をもう一度見る…") { SettingsProcess.open(.onboarding) }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .onReceive(timer) { _ in refresh() }
    }

    private func refresh() {
        trusted = KeySender.isTrusted
        conflicts = SystemGestureChecker.conflicts(fingers: fingers)
        loginItem = SMAppService.mainApp.status == .enabled
    }

    private func setLoginItem(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            // 失敗したら現在の状態に戻すだけ（/Applications 以外から起動していると失敗することがある）
        }
        loginItem = SMAppService.mainApp.status == .enabled
    }
}
