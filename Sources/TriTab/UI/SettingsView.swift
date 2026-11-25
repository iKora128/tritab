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
            case .swipe: return L("スワイプ", "Swipe")
            case .tapClick: return L("タップとクリック", "Tap & Click")
            case .input: return L("日本語入力", "Japanese Input")
            case .shelf: return L("ノッチのトレイ", "Notch Shelf")
            case .apps: return L("対象アプリ", "Apps")
            case .general: return L("一般", "General")
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
                            Text(enabled ? L("動作中", "Active") : L("停止中", "Paused"))
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
    @AppStorage("fiveFingerUp") private var fiveFingerUp: FiveFingerSwipeUp = .off

    var body: some View {
        Form {
            Section {
                PaneHeader(symbol: "hand.draw.fill", color: Sunset.rose, fill: Sunset.badge(0), title: L("スワイプでタブを操作", "Swipe to Control Tabs"),
                           subtitle: L("\(fingers)本指で払うと、1回につき1つだけ動きます。",
                                       "Swipe with \(fingers) fingers. Each swipe triggers one action."))
            }
            Section(L("ジェスチャー", "Gestures")) {
                GestureRow(kind: .swipe(.left, fingers: fingers), title: L("左へスワイプ", "Swipe left")) {
                    Text(leftIsNext ? L("次のタブ", "Next Tab") : L("前のタブ", "Previous Tab")).foregroundStyle(.secondary)
                }
                GestureRow(kind: .swipe(.right, fingers: fingers), title: L("右へスワイプ", "Swipe right")) {
                    Text(leftIsNext ? L("前のタブ", "Previous Tab") : L("次のタブ", "Next Tab")).foregroundStyle(.secondary)
                }
                GestureRow(kind: .swipe(.up, fingers: fingers), title: L("上へスワイプ", "Swipe up")) {
                    Picker("", selection: $upAction) {
                        ForEach([TabAction.reopenTab, .newTab, .none], id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                GestureRow(kind: .swipe(.down, fingers: fingers), title: L("下へスワイプ", "Swipe down")) {
                    Picker("", selection: $downAction) {
                        ForEach([TabAction.closeTab, .none], id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
            Section(L("ほかのスワイプ", "Other Swipes")) {
                GestureRow(kind: .swipe(.up, fingers: 5), title: L("5本指で上へスワイプ", "Swipe up with 5 fingers"),
                           detail: L("席を外すときに、すぐスリープ", "Sleep right away when you step away")) {
                    Picker("", selection: $fiveFingerUp) {
                        ForEach(FiveFingerSwipeUp.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
            Section {
                Picker(L("左右の向き", "Left/right direction"), selection: $leftIsNext) {
                    Text(L("左へ払うと次（右）のタブ", "Swipe left for the next tab (to the right)")).tag(true)
                    Text(L("左へ払うと前（左）のタブ", "Swipe left for the previous tab (to the left)")).tag(false)
                }
                Picker(L("指の本数", "Number of fingers"), selection: $fingers) {
                    Text(L("3本指", "3 fingers")).tag(3)
                    Text(L("4本指", "4 fingers")).tag(4)
                }
                Picker(L("感度", "Sensitivity"), selection: $sensitivity) {
                    ForEach(Sensitivity.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle(isOn: $swipeReverse) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("指を離さずに左右に往復", "Swipe back and forth without lifting"))
                        Text(L("右へ払ったあと、そのまま左へ戻すともう一度移動します",
                               "After swiping right, swipe back left without lifting to move again."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text(L("「3本指のドラッグ」を使っている場合は 4本指にしてください。", "If you use Three Finger Drag, switch to 4 fingers."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            DragSpaceSection(fingers: fingers)
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

    var body: some View {
        Form {
            Section {
                PaneHeader(symbol: "hand.tap.fill", color: Sunset.pink, fill: Sunset.badge(1), title: L("タップ・クリック・つまむ", "Tap, Click, and Pinch"),
                           subtitle: L("リンクを新しいタブで開く、再読み込みなどをジェスチャーで。",
                                       "Open links in new tabs, reload, and more with gestures."))
            }
            Section(L("タブ", "Tabs")) {
                GestureRow(kind: .tap(fingers: fingers), title: L("\(fingers)本指でタップ", "Tap with \(fingers) fingers"),
                           detail: L("新しいタブを開く", "Open new tab")) {
                    Toggle("", isOn: $tapNewTab).labelsHidden()
                }
                GestureRow(kind: .click(fingers: fingers), title: L("\(fingers)本指でクリック", "Click with \(fingers) fingers"),
                           detail: L("⌘クリック（リンクを新しいタブで開く）", "⌘-click (open link in new tab)")) {
                    Toggle("", isOn: $clickCmd).labelsHidden()
                }
                GestureRow(kind: .click(fingers: fingers + 1), title: L("\(fingers + 1)本指でクリック", "Click with \(fingers + 1) fingers"),
                           detail: L("閉じたタブを復元", "Reopen closed tab")) {
                    Toggle("", isOn: $clickReopen).labelsHidden()
                }
                GestureRow(kind: .pinch, title: L("親指＋2本指でつまむ", "Pinch with thumb and 2 fingers"),
                           detail: L("再読み込み", "Reload")) {
                    Toggle("", isOn: $pinchReload).labelsHidden()
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
                PaneHeader(symbol: "character.bubble.fill", color: Sunset.fuchsia, fill: Sunset.badge(2), title: L("英数／かなをすばやく切り替え", "Quickly Switch Between Eisu (英数) and Kana (かな)"),
                           subtitle: L("Karabiner-Elements の定番設定と同じ操作を、TriTab だけで。",
                                       "Works like the classic Karabiner-Elements setup, with just TriTab."))
            }
            Section {
                HStack(spacing: 12) {
                    KeyCap(text: "⌘", caption: L("左", "Left"))
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    Text(L("英数", "Eisu")).font(.headline)
                    Spacer().frame(width: 24)
                    KeyCap(text: "⌘", caption: L("右", "Right"))
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    Text(L("かな", "Kana")).font(.headline)
                    Spacer()
                    Toggle("", isOn: $imeCmd).labelsHidden()
                }
                .padding(.vertical, 4)
            } header: {
                Text(L("⌘キーを単体で押す", "Press ⌘ Alone"))
            } footer: {
                Text(L("⌘を押して、ほかのキーを押さずに離したときだけ切り替わります。⌘C などのショートカットはそのまま使えます。パスワード入力欄では macOS の制限で切り替わりません。",
                       "It switches only when you press and release ⌘ without pressing any other key. Shortcuts like ⌘C work as usual. Because of a macOS limitation, it doesn’t switch in password fields."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("トラックパッド", "Trackpad")) {
                GestureRow(kind: .tap(fingers: fingers + 1), title: L("\(fingers + 1)本指でタップ", "Tap with \(fingers + 1) fingers"),
                           detail: L("英数 ⇄ かな を切り替え", "Toggle Eisu ⇄ Kana")) {
                    Toggle("", isOn: $imeTap).labelsHidden()
                }
            }
            if FileManager.default.fileExists(atPath: "/Applications/Karabiner-Elements.app") {
                Section {
                    Label(L("Karabiner-Elements で同じルール（⌘単体で英数／かな）を使っている場合は、そちらをオフにしてください。",
                            "If you use the same rule (⌘ alone for Eisu/Kana) in Karabiner-Elements, turn it off there."),
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

// MARK: - ノッチのトレイ

private struct ShelfPane: View {
    @AppStorage("shelf") private var shelf = false
    @AppStorage("shelfAnimation") private var animation: ShelfAnimationStyle = .jelly
    @AppStorage("shelfDropMode") private var dropMode: ShelfDropMode = .reference
    @AppStorage("shelfAutoRemove") private var autoRemoveDays = 0

    var body: some View {
        Form {
            Section {
                PaneHeader(symbol: "tray.full.fill", color: Sunset.purple, fill: Sunset.badge(3), title: L("ノッチのトレイ", "Notch Shelf"),
                           subtitle: L("ファイルや画像、テキストを、ノッチにいったん置いておけます。",
                                       "Stash files, images, and text in the notch. Drop them anywhere later."))
            }
            Section {
                Toggle(L("ノッチのトレイを使う", "Use the Notch Shelf"), isOn: $shelf)
            }
            Section {
                Picker(L("置き方", "When You Drop Files"), selection: $dropMode) {
                    Text(L("参照で置く（元の場所のまま）", "Add a Reference (the file stays where it is)")).tag(ShelfDropMode.reference)
                    Text(L("コピーして置く（複製を作り、元のファイルはそのまま）", "Add a Copy (the original stays untouched)")).tag(ShelfDropMode.copy)
                }
            } footer: {
                Text(L("開いているときにノッチの横に出るスイッチでも切り替えられます。ドラッグ中に ⌥ を押しながら離すとコピー、⌘⌥ なら参照になります。ブラウザの画像やリンク、テキストは、どちらを選んでいても TriTab の中に保存します。",
                       "You can also change this with the switch next to the notch while the shelf is open. While dragging, hold ⌥ to add a copy, or ⌘⌥ to add a reference. Images, links, and text from a browser are always saved on the shelf."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker(L("古い項目を自動で削除", "Remove Old Items"), selection: $autoRemoveDays) {
                    Text(L("しない", "Never")).tag(0)
                    Text(L("置いてから 1 日たったら", "After 1 Day")).tag(1)
                    Text(L("置いてから 3 日たったら", "After 3 Days")).tag(3)
                    Text(L("置いてから 1 週間たったら", "After 1 Week")).tag(7)
                    Text(L("置いてから 1 か月たったら", "After 1 Month")).tag(30)
                }
            } footer: {
                Text(L("置いてからこの期間がたった項目を、古いものから順に削除します。コピーとメモはゴミ箱に入れるので、あとから戻せます。参照で置いたものはトレイから消えるだけで、元のファイルは削除しません。項目にマウスを乗せると、削除されるころがわかります。",
                       "Items leave the shelf, oldest first, once they’ve been there this long. Copies and notes go to the Trash, so you can get them back. For references, only the shelf item goes away; the original file is never touched. Hover over an item to see when it will be removed."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker(L("動き", "Motion"), selection: $animation) {
                    ForEach(ShelfAnimationStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                HStack {
                    Button {
                        ShelfPreview.post(animation)
                    } label: {
                        Label(L("この動きを試す", "Try This Motion"), systemImage: "play.fill")
                    }
                    .buttonStyle(SunsetButtonStyle())
                    Button {
                        ShelfPreview.post(nil)
                    } label: {
                        Label(L("全部の動きを順番に見る", "Play All in Order"), systemImage: "play.square.stack")
                    }
                    Spacer()
                }
            } header: {
                Text(L("アニメーション", "Animation"))
            } footer: {
                Text(L("ボタンを押すと、画面上部のノッチで実際に開いたり閉じたりします。",
                       "Press a button to watch the shelf move in the notch at the top of your screen."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("使い方", "How to Use")) {
                Step(number: 1, text: L("ファイルやブラウザの画像をドラッグして少し上へ動かすと、ノッチの下にトレイが開き始め、画面の上端に近づけると大きく開く。リンクやテキストは、ノッチまで持っていくと開く",
                                        "Drag a file or an image from your browser and nudge it upward. The shelf peeks out of the notch and opens wide as you get close. For links and text, bring them to the notch to open the shelf."))
                Step(number: 2, text: L("そのまま落とす。ファイルは、ノッチの横のスイッチで選んだ置き方（参照かコピー）で置かれる。画像とリンクはファイルにして保存し、テキストはメモになる。一度に複数のファイルを落とすと、ひとまとめになる",
                                        "Drop it on the shelf. Files are added the way the switch next to the notch says (reference or copy). Images and links are saved on the shelf, and text becomes a note. Several files dropped at once become one stack."))
                Step(number: 3, text: L("ノッチにマウスを乗せても開く。開いているあいだは ⌘V でクリップボードの中身を置ける",
                                        "Hovering over the notch also opens the shelf. While it’s open, press ⌘V to add what’s on the clipboard."))
                Step(number: 4, text: L("置いたファイルを好きな場所へドラッグすると、そこへ移動してトレイから消える。参照なら元のファイルが、コピーなら複製のほうが移動する。⌥を押しながらなら行き先に複製を置き、トレイにも残る",
                                        "Drag items from the shelf to wherever you like. They move there and leave the shelf: a reference moves the original, a copy moves the shelf’s duplicate. Hold ⌥ to drop a duplicate and keep the item."))
                Step(number: 5, text: L("⌘クリックや⇧クリック、⌘A でまとめて選べる。右クリックすると「Finder で表示」などのメニューが出る",
                                        "⌘-click, ⇧-click, or ⌘A selects several items. Right-click for Show in Finder and more."))
            }
        }
        .formStyle(.grouped)
    }
}

/// 設定画面 → 常駐側へ「トレイのアニメーションを見せて」
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
                PaneHeader(symbol: "square.grid.2x2.fill", color: Sunset.violet, fill: Sunset.badge(4), title: L("対象アプリ", "Apps"),
                           subtitle: L("アプリごとにショートカットの違いを自動で切り替えます。",
                                       "Automatically switches shortcuts to match each app."))
            }
            Section {
                Toggle(L("登録のないアプリでも動かす", "Also work in unlisted apps"), isOn: $allApps)
            } footer: {
                Text(L("オンにすると、登録のないアプリには ⌃Tab / ⌘W / ⇧⌘T を送ります。", "When on, TriTab sends ⌃Tab / ⌘W / ⇧⌘T to unlisted apps."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("専用の設定があるアプリ", "Apps with Custom Settings")) {
                ForEach(AppProfiles.supportedAppNames, id: \.self) { name in
                    Text(name)
                }
            }
            Section {
                Text(L("ターミナル系では「閉じる」「復元」を送りません（実行中の処理を閉じてしまわないように）。Slack・Discord・メールでは何もしません。",
                       "In terminal apps, TriTab never sends Close Tab or Reopen Closed Tab, so running processes aren’t closed by mistake. It does nothing in Slack, Discord, or Mail."))
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
                PaneHeader(symbol: "gearshape.fill", color: .gray, title: L("一般", "General"),
                           subtitle: L("起動、表示、許可の状態。", "Startup, display, and permission status."))
            }
            Section(L("動作", "Behavior")) {
                Toggle(L("ログイン時に起動", "Open at login"), isOn: Binding(get: { loginItem }, set: setLoginItem))
                Toggle(L("操作した内容を画面に表示", "Show actions on screen"), isOn: $showHUD)
                Toggle(L("操作時にトラックパッドを振動（小さな音が鳴ります）", "Haptic feedback on each action (makes a faint sound)"),
                       isOn: $haptic)
            }
            Section(L("状態", "Status")) {
                LabeledContent(L("アクセシビリティ", "Accessibility")) {
                    if trusted {
                        StatusPill(ok: true, text: L("許可済み", "Allowed"))
                    } else {
                        Button(L("許可する…", "Allow…")) { KeySender.requestTrust() }.buttonStyle(SunsetButtonStyle())
                    }
                }
                LabeledContent(L("macOS のジェスチャー", "macOS gestures")) {
                    if conflicts.isEmpty {
                        StatusPill(ok: true, text: L("競合なし", "No conflicts"))
                    } else {
                        Button(L("トラックパッド設定を開く…", "Open Trackpad Settings…")) { SystemGestureChecker.openTrackpadSettings() }
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
                Button(L("はじめの案内をもう一度見る…", "Show Welcome Guide Again…")) { SettingsProcess.open(.onboarding) }
                LabeledContent(L("バージョン", "Version")) {
                    Text(Self.version).foregroundStyle(.secondary).textSelection(.enabled)
                }
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

    /// 版とビルドの日時（ビルド番号は yyyyMMddHHmm。同じ版のまま作り直したものを見分けられるように、日時で出す）
    private static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? ""
        let parser = DateFormatter()
        parser.dateFormat = "yyyyMMddHHmm"
        parser.locale = Locale(identifier: "en_US_POSIX")
        guard let date = parser.date(from: build) else { return build.isEmpty ? short : "\(short) (\(build))" }
        let shown = date.formatted(date: .numeric, time: .shortened)
        return L("\(short)（\(shown) のビルド）", "\(short) (built \(shown))")
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
