import AppKit
import SwiftUI
import TriTabCore

/// はじめての案内（ようこそ → アクセシビリティ → macOS のジェスチャー → 試してみる → 完了）
struct OnboardingView: View {
    enum Page: Int, CaseIterable { case welcome, permission, conflicts, tryIt, done }

    var onFinish: () -> Void

    @State private var page: Page = .welcome
    @State private var forward = true
    @State private var trusted = KeySender.isTrusted
    @State private var conflicts: [GestureConflict] = []
    @AppStorage("fingers") private var fingers = 3
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            VisualEffectBackground(material: .underWindowBackground).ignoresSafeArea()
            LinearGradient(colors: [Sunset.rose.opacity(0.16), Sunset.violet.opacity(0.10), Color.clear],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                ZStack {
                    content
                        .id(page)
                        .transition(.asymmetric(
                            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

                footer
            }
        }
        .frame(width: 680, height: 540)
        .onAppear(perform: refresh)
        .onReceive(timer) { _ in refresh() }
    }

    @ViewBuilder private var content: some View {
        switch page {
        case .welcome: WelcomePage(fingers: fingers)
        case .permission: PermissionPage(trusted: trusted)
        case .conflicts: ConflictsPage(conflicts: conflicts, fingers: fingers)
        case .tryIt: TryItPage(fingers: fingers)
        case .done: DonePage()
        }
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 7) {
                ForEach(Page.allCases, id: \.self) { p in
                    Capsule()
                        .fill(p == page ? AnyShapeStyle(Sunset.gradient) : AnyShapeStyle(Color.primary.opacity(0.18)))
                        .frame(width: p == page ? 18 : 7, height: 7)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: page)

            Spacer()

            if page != .welcome && page != .done {
                Button("戻る") { go(-1) }
                    .controlSize(.large)
            }
            Button(nextTitle) {
                if page == .done { onFinish() } else { go(1) }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(SunsetButtonStyle(large: true))
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
    }

    private var nextTitle: String {
        switch page {
        case .welcome: return "はじめる"
        case .permission: return trusted ? "次へ" : "あとで"
        case .conflicts: return "次へ"
        case .tryIt: return "次へ"
        case .done: return "完了"
        }
    }

    private func go(_ delta: Int) {
        guard let next = Page(rawValue: page.rawValue + delta) else { return }
        forward = delta > 0
        withAnimation(.spring(response: 0.45, dampingFraction: 0.88)) { page = next }
    }

    private func refresh() {
        let nowTrusted = KeySender.isTrusted
        if nowTrusted != trusted {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { trusted = nowTrusted }
        }
        conflicts = SystemGestureChecker.conflicts(fingers: fingers)
    }
}

// MARK: - 共通レイアウト

private struct PageLayout<Hero: View, Body: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var hero: () -> Hero
    @ViewBuilder var content: () -> Body

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 24)
            hero()
            VStack(spacing: 8) {
                Text(title).font(.system(size: 28, weight: .bold))
                Text(subtitle)
                    .font(.title3).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content()
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 48)
    }
}

/// 大きなアイコン（グラデーションの光るタイル）
private struct HeroTile<Inner: View>: View {
    let colors: [Color]
    @ViewBuilder var inner: () -> Inner

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: colors.first!.opacity(0.45), radius: 18, y: 8)
            inner()
        }
        .frame(width: 112, height: 112)
    }
}

// MARK: - ページ

private struct WelcomePage: View {
    let fingers: Int

    var body: some View {
        PageLayout(title: "TriTab へようこそ",
                   subtitle: "トラックパッドだけで、タブをすばやく操作。") {
            HeroTile(colors: [Color(red: 0.98, green: 0.44, blue: 0.52), Color(red: 0.49, green: 0.23, blue: 0.93)]) {
                GestureIllustration(kind: .swipe(.left, fingers: 3), width: 84, tint: .white)
            }
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                Feature(symbol: "hand.draw.fill", color: Sunset.rose,
                        title: "\(fingers)本指でタブを移動・閉じる・復元",
                        detail: "左右で移動、下で閉じる、上で閉じたタブを元に戻す。")
                Feature(symbol: "hand.tap.fill", color: Sunset.fuchsia,
                        title: "タップやクリックで、新しいタブ",
                        detail: "\(fingers)本指クリックでリンクを新しいタブで開く。")
                Feature(symbol: "leaf.fill", color: Sunset.violet,
                        title: "軽い",
                        detail: "常駐しても約 11 MB。設定画面は開いたときだけ。")
            }
            .padding(.top, 10)
        }
    }
}

private struct Feature: View {
    let symbol: String
    let color: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            IconBadge(symbol: symbol, color: color, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 420, alignment: .leading)
    }
}

private struct PermissionPage: View {
    let trusted: Bool

    var body: some View {
        PageLayout(title: "アクセシビリティを許可",
                   subtitle: "スワイプをタブ操作のキーに変えるために必要です。\n入力内容を読み取ったり、送信したりはしません。") {
            HeroTile(colors: trusted ? [.green, .mint] : [Sunset.rose, Sunset.violet]) {
                Image(systemName: trusted ? "checkmark" : "hand.raised.fill")
                    .font(.system(size: 50, weight: .semibold)).foregroundStyle(.white)
            }
        } content: {
            VStack(spacing: 14) {
                if trusted {
                    StatusPill(ok: true, text: "許可されました")
                        .font(.title3)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Button {
                        KeySender.requestTrust()
                        SystemGestureChecker.openAccessibilitySettings()
                    } label: {
                        Label("システム設定を開く", systemImage: "arrow.up.forward.app")
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(SunsetButtonStyle(large: true))
                    Text("一覧の「TriTab」をオンにすると、自動で次へ進めるようになります。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 8)
        }
    }
}

private struct ConflictsPage: View {
    let conflicts: [GestureConflict]
    let fingers: Int

    var body: some View {
        PageLayout(title: "macOS のジェスチャーを確認",
                   subtitle: conflicts.isEmpty
                       ? "\(fingers)本指のジェスチャーは TriTab だけが使える状態です。"
                       : "macOS 側の\(fingers)本指ジェスチャーも同時に動いてしまいます。\n次の設定を変更してください。") {
            HeroTile(colors: conflicts.isEmpty ? [.green, .mint] : [Sunset.rose, Sunset.fuchsia]) {
                Image(systemName: conflicts.isEmpty ? "checkmark" : "rectangle.and.hand.point.up.left.filled")
                    .font(.system(size: conflicts.isEmpty ? 50 : 42, weight: .semibold)).foregroundStyle(.white)
            }
        } content: {
            if conflicts.isEmpty {
                StatusPill(ok: true, text: "競合はありません").font(.title3)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(conflicts, id: \.title) { c in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.title).font(.headline)
                                Text(c.fix).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button {
                        SystemGestureChecker.openTrackpadSettings()
                    } label: {
                        Label("トラックパッド設定を開く", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(SunsetButtonStyle())
                    .padding(.top, 4)
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.background.opacity(0.6)))
            }
        }
    }
}

/// 実際にジェスチャーをしてもらい、検出できたものに ✓ を付ける
private struct TryItPage: View {
    let fingers: Int
    @State private var done: Set<String> = []

    private var items: [(id: String, kind: GestureIllustration.Kind, title: String)] {
        [("swipe-left-\(fingers)", .swipe(.left, fingers: fingers), "左へスワイプ"),
         ("swipe-right-\(fingers)", .swipe(.right, fingers: fingers), "右へスワイプ"),
         ("swipe-down-\(fingers)", .swipe(.down, fingers: fingers), "下へスワイプ"),
         ("swipe-up-\(fingers)", .swipe(.up, fingers: fingers), "上へスワイプ"),
         ("tap-\(fingers)", .tap(fingers: fingers), "\(fingers)本指でタップ")]
    }

    var body: some View {
        PageLayout(title: "試してみよう",
                   subtitle: "トラックパッドでやってみてください。うまくできたら ✓ が付きます。\nこの画面では、実際のタブ操作は行いません。") {
            EmptyView()
        } content: {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(108), spacing: 12), count: 5), spacing: 12) {
                ForEach(items, id: \.id) { item in
                    let ok = done.contains(item.id)
                    VStack(spacing: 8) {
                        ZStack(alignment: .topTrailing) {
                            GestureIllustration(kind: item.kind, width: 78, tint: ok ? .green : Sunset.accent, animated: !ok)
                            if ok {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.title2).foregroundStyle(.white, .green)
                                    .offset(x: 8, y: -8)
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }
                        Text(item.title).font(.callout.weight(.medium))
                    }
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(ok ? Color.green.opacity(0.12) : Color.primary.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(ok ? Color.green.opacity(0.6) : Color.primary.opacity(0.08), lineWidth: 1)
                    )
                }
            }
            .padding(.top, 8)
            if done.count == items.count {
                Text("完璧です！").font(.title3.weight(.semibold)).foregroundStyle(.green)
                    .transition(.opacity)
            }
        }
        .onReceive(DistributedNotificationCenter.default().publisher(for: GestureBroadcast.name)) { note in
            guard let id = note.userInfo?["event"] as? String, items.contains(where: { $0.id == id }) else { return }
            _ = withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { done.insert(id) }
        }
    }
}

private struct DonePage: View {
    @AppStorage("imeCmd") private var imeCmd = false
    @AppStorage("shelf") private var shelf = false

    var body: some View {
        PageLayout(title: "準備ができました",
                   subtitle: "メニューバーのアイコンから、いつでも設定を開けます。") {
            HeroTile(colors: [.green, .teal]) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 52, weight: .semibold)).foregroundStyle(.white)
            }
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                Text("こちらもどうぞ").font(.headline).foregroundStyle(.secondary)
                // 日本語を使っていない人には関係ないので出さない
                if Settings.usesJapaneseInput {
                    Toggle(isOn: $imeCmd) {
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("⌘単体で英数／かな")
                                Text("左⌘で英数、右⌘でかな").font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { IconBadge(symbol: "character.bubble.fill", color: Sunset.fuchsia, size: 26, fill: Sunset.badge(2)) }
                    }
                }
                Toggle(isOn: $shelf) {
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("ノッチの棚")
                            Text("ファイルをノッチに一時置き").font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { IconBadge(symbol: "tray.full.fill", color: Sunset.purple, size: 26, fill: Sunset.badge(3)) }
                }
            }
            .toggleStyle(SunsetToggleStyle())
            .frame(width: 360)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.background.opacity(0.6)))
        }
    }
}

/// 常駐側 → 案内画面へ、検出したジェスチャーを知らせる
enum GestureBroadcast {
    static let name = Notification.Name("io.github.ikora128.TriTab.gesture")

    static func id(for event: GestureEvent) -> String {
        switch event {
        case let .swipe(d, n): return "swipe-\(d.rawValue)-\(n)"
        case let .tap(n): return "tap-\(n)"
        case let .pinchIn(n): return "pinch-\(n)"
        }
    }

    static func post(_ event: GestureEvent) {
        DistributedNotificationCenter.default().postNotificationName(
            name, object: nil, userInfo: ["event": id(for: event)], deliverImmediately: true)
    }
}
