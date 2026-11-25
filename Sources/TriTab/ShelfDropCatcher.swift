import AppKit

/// ファイルなどを持ってきているあいだだけ、広げたトレイに重ねて出す透明なウィンドウ。ここでドロップを受ける。
///
/// トレイは広がる動きの途中で形も大きさも変わる。トレイそのものを受け取り先にすると、動いている縁のあたりで
/// 「トレイの外」になったり戻ったりして、光ったり消えたりし、離しても受け取れないことがある。
/// そこで受け取り先は、出したら大きさを変えない別のウィンドウにし、広げたトレイより一回り大きく取る。
/// 受け取った知らせは、そのままトレイの土台（ShelfStage）へ渡す（光らせ方と受け取り方は土台が決める）
final class ShelfDropCatcher: NSPanel {
    /// 知らせを渡す先
    weak var target: ShelfStage?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // 透明なウィンドウは、塗っていないところではマウスもドラッグも受けない。false を明示すると、枠の中ならどこでも受ける
        // （念のため、見えないほど薄くも塗っておく）
        ignoresMouseEvents = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3) // トレイ（+2）より上
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        let view = CatcherView()
        view.owner = self
        contentView = view
    }

    final class CatcherView: NSView {
        weak var owner: ShelfDropCatcher?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.withAlphaComponent(0.01).cgColor
            registerForDraggedTypes(ShelfDrop.acceptedTypes)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            owner?.target?.draggingEntered(sender) ?? []
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            owner?.target?.draggingUpdated(sender) ?? []
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            owner?.target?.draggingExited(sender)
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            owner?.target?.performDragOperation(sender) ?? false
        }

        override func draggingEnded(_ sender: NSDraggingInfo) {
            owner?.target?.draggingEnded(sender)
        }
    }
}
