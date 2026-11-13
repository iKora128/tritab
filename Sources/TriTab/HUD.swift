import AppKit

/// 操作したことが一瞬わかる小さな表示。誤って閉じたときにすぐ気づけるようにする。
/// パネルは初回表示時に 1 つだけ作って使い回す。
final class HUD {
    static let shared = HUD()

    private var panel: NSPanel?
    private var label: NSTextField?
    private var hideWork: DispatchWorkItem?

    func show(_ text: String) {
        let (panel, label) = makeIfNeeded()
        label.stringValue = text
        label.sizeToFit()

        let size = NSSize(width: label.frame.width + 40, height: label.frame.height + 22)
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            panel.setFrame(NSRect(x: f.midX - size.width / 2, y: f.minY + f.height * 0.15,
                                  width: size.width, height: size.height), display: false)
        }
        label.frame.origin = NSPoint(x: 20, y: 11)

        hideWork?.cancel()
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        let work = DispatchWorkItem { [weak panel] in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                panel?.animator().alphaValue = 0
            }, completionHandler: {
                panel?.orderOut(nil)
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func makeIfNeeded() -> (NSPanel, NSTextField) {
        if let panel, let label { return (panel, label) }

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 44),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        background.autoresizingMask = [.width, .height]
        panel.contentView = background

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 17, weight: .medium)
        label.textColor = .labelColor
        background.addSubview(label)

        self.panel = panel
        self.label = label
        return (panel, label)
    }
}
