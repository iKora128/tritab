import SwiftUI
import TriTabCore

/// 設定画面「スワイプ」の「ドラッグ中」の欄: ドラッグ中のスワイプで隣のデスクトップへ
struct DragSpaceSection: View {
    let fingers: Int
    @AppStorage("dragSpaces") private var dragSpaces = false
    @State private var shortcutOn = SpaceSwitcher.isAvailable
    @State private var threeFingerDrag = SystemGestureChecker.threeFingerDragEnabled
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Section {
            GestureRow(kind: .holdSwipe(.left, fingers: fingers),
                       title: L("ドラッグ中に左右へスワイプ", "Swipe while dragging"),
                       detail: L("隣のデスクトップへ移る（つかんでいるものも一緒に）",
                                 "Move to the next desktop, along with what you’re dragging")) {
                Toggle("", isOn: $dragSpaces).labelsHidden()
            }
            .onAppear(perform: refresh)
            .onReceive(timer) { _ in refresh() }
            if dragSpaces && fingers == 3 && threeFingerDrag {
                Label(L("「3本指のドラッグ」を使っているので、3本指モードでは働きません。指の本数を4本にすると使えます。",
                        "This doesn’t work in 3-finger mode while Three Finger Drag is on. Switch to 4 fingers to use it."),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            }
            if dragSpaces && !shortcutOn {
                VStack(alignment: .leading, spacing: 6) {
                    Label(L("Mission Control の「左の操作スペースに移動」「右の操作スペースに移動」がオフになっています",
                            "Mission Control’s “Move left a space” and “Move right a space” shortcuts are off"),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                    Text(L("キーボード › キーボードショートカット… › Mission Control でオンにしてください。",
                           "Turn them on in Keyboard › Keyboard Shortcuts… › Mission Control."))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(L("キーボード設定を開く…", "Open Keyboard Settings…")) { SpaceSwitcher.openShortcutSettings() }
                        .buttonStyle(SunsetButtonStyle())
                }
            }
        } header: {
            Text(L("ドラッグ中", "While Dragging"))
        } footer: {
            Text(L("ウィンドウやファイルを1本の指で押さえてドラッグしたまま、ほかの\(fingers)本で払います。Mission Control のショートカット（⌃← / ⌃→）で移ります。",
                   "Keep one finger pressed on a window or file while dragging, and swipe with \(fingers) other fingers. TriTab uses the Mission Control shortcuts (⌃← / ⌃→)."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func refresh() {
        shortcutOn = SpaceSwitcher.isAvailable
        threeFingerDrag = SystemGestureChecker.threeFingerDragEnabled
    }
}
