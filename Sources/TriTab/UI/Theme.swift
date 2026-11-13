import SwiftUI

/// 配色（案 B: 背景は macOS 標準、アクセントだけアイコンと同じ夕焼け）
enum Sunset {
    static let rose = Color(red: 0.984, green: 0.443, blue: 0.522)     // #FB7185
    static let pink = Color(red: 0.925, green: 0.282, blue: 0.600)     // #EC4899
    static let fuchsia = Color(red: 0.851, green: 0.275, blue: 0.937)  // #D946EF
    static let purple = Color(red: 0.659, green: 0.333, blue: 0.969)   // #A855F7
    static let lilac = Color(red: 0.753, green: 0.518, blue: 0.988)    // #C084FC
    static let violet = Color(red: 0.486, green: 0.227, blue: 0.929)   // #7C3AED

    /// スイッチやピッカーなど 1 色で塗る部品の色
    static let accent = purple

    static let gradient = LinearGradient(colors: [rose, lilac, violet],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)

    /// サイドバーのアイコンの色（ローズ → すみれ の同系色）
    static func badge(_ i: Int) -> LinearGradient {
        let pairs: [(Color, Color)] = [
            (rose, Color(red: 0.957, green: 0.247, blue: 0.369)),   // ローズ
            (Color(red: 0.957, green: 0.447, blue: 0.714), pink),   // ピンク
            (Color(red: 0.910, green: 0.475, blue: 0.976), fuchsia),// フューシャ
            (lilac, purple),                                        // パープル
            (Color(red: 0.655, green: 0.545, blue: 0.980), violet), // すみれ
        ]
        let p = pairs[min(max(i, 0), pairs.count - 1)]
        return LinearGradient(colors: [p.0, p.1], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// 主ボタン（夕焼けのグラデーション）
struct SunsetButtonStyle: ButtonStyle {
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(large ? .body.weight(.semibold) : .callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, large ? 18 : 12)
            .padding(.vertical, large ? 8 : 5)
            .background(
                RoundedRectangle(cornerRadius: large ? 10 : 7, style: .continuous)
                    .fill(Sunset.gradient)
                    .shadow(color: Sunset.fuchsia.opacity(0.35), radius: configuration.isPressed ? 2 : 6, y: 2)
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// スイッチ（オンのとき夕焼けのグラデーション）
struct SunsetToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer(minLength: 8)
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? AnyShapeStyle(Sunset.gradient) : AnyShapeStyle(Color.primary.opacity(0.18)))
                    .frame(width: 38, height: 22)
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                    .frame(width: 18, height: 18)
                    .padding(2)
            }
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isOn)
            .onTapGesture { configuration.isOn.toggle() }
            .accessibilityElement()
            .accessibilityLabel("スイッチ")
            .accessibilityValue(configuration.isOn ? "オン" : "オフ")
            .accessibilityAddTraits(.isButton)
        }
    }
}
