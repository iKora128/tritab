import AppKit
import TriTabCore

// MARK: - 右クリックメニューと、選んだ項目への操作

extension ShelfController {
    /// 項目の右クリックメニュー。選んである項目の上なら選んだもの全部、そうでなければその項目だけが対象
    func contextMenu(for id: UUID) -> NSMenu {
        if !isSelected(id) { select(id) }
        refreshItems(selectedItems.map(\.id))
        let targets = selectedItems
        let available = targets.filter(\.isAvailable)
        let n = targets.count
        let fileCount = targets.reduce(0) { $0 + $1.files.count }

        let menu = NSMenu()
        menu.autoenablesItems = false
        // 1 つのときは、どう置いたものかを先頭に出す
        if n == 1, let item = targets.first {
            let info = NSMenuItem(title: item.summary, action: nil, keyEquivalent: "")
            info.isEnabled = false
            if let badge = item.badge {
                info.image = NSImage(systemSymbolName: badge.symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold).applying(.init(paletteColors: [badge.color])))
            }
            menu.addItem(info)
            menu.addItem(.separator())
        }
        menu.addItem(action(fileCount > 1 ? L("\(fileCount) 項目を開く", "Open \(fileCount) Items") : L("開く", "Open"),
                            enabled: !available.isEmpty) { [weak self] in self?.open(available) })
        menu.addItem(action(fileCount > 1 ? L("\(fileCount) 項目を Quick Look", "Quick Look \(fileCount) Items") : "Quick Look",
                            enabled: !available.isEmpty) { [weak self] in self?.showQuickLook(available) })
        menu.addItem(action(L("Finder で表示", "Show in Finder"), enabled: !available.isEmpty) { [weak self] in
            self?.reveal(available)
        })
        let references = targets.filter { $0.kind == .reference }
        if !references.isEmpty {
            menu.addItem(.separator())
            let copyable = references.filter(\.isAvailable).map(\.id)
            let title = references.count > 1 ? L("棚にコピーを作る（\(references.count) 項目）", "Make Copies of \(references.count) Items on the Shelf")
                                             : L("棚にコピーを作る", "Make a Copy on the Shelf")
            let make = action(title, enabled: !copyable.isEmpty) { [weak self] in self?.makeCopies(copyable) }
            make.toolTip = L("元のファイルはそのまま残します。このあと外へドラッグすると、棚のコピーのほうが移動します",
                             "The original stays where it is. Dragging out then moves the shelf’s copy instead of the original.")
            menu.addItem(make)
        }
        let groups = targets.filter(\.isGroup).map(\.id)
        if !groups.isEmpty {
            menu.addItem(.separator())
            let ungroup = action(L("1 つずつに分ける", "Ungroup"), enabled: groups.contains { !isCopying($0) }) { [weak self] in
                self?.ungroup(groups)
            }
            ungroup.toolTip = L("まとめて置いたファイルを、棚の上で 1 つずつの項目に分けます",
                                "Splits the stack into separate items on the shelf.")
            menu.addItem(ungroup)
        }
        menu.addItem(.separator())
        let ids = targets.map(\.id)
        let remove = action(n > 1 ? L("\(n) 項目を棚から外す", "Remove \(n) Items from Shelf") : L("棚から外す", "Remove from Shelf")) {
            [weak self] in self?.remove(ids)
        }
        if targets.contains(where: { $0.kind != .reference }) {
            remove.toolTip = L("棚の中のコピーとメモは、ゴミ箱へ移します", "Copies and notes on the shelf are moved to the Trash.")
        }
        menu.addItem(remove)
        return menu
    }

    /// 項目のないところの右クリックメニュー
    func backgroundMenu() -> NSMenu? {
        guard !items.isEmpty else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let all = action(L("すべてを選択", "Select All")) { [weak self] in self?.selectAll() }
        all.keyEquivalent = "a" // ⌘A（棚が開いているあいだ効く）
        menu.addItem(all)
        menu.addItem(action(L("棚を空にする", "Clear Shelf")) { [weak self] in self?.removeAll() })
        return menu
    }

    /// メニューを出す。開いているあいだは棚を閉じない
    func popUp(_ menu: NSMenu, with event: NSEvent, for view: NSView) {
        menuOpen = true
        NSMenu.popUpContextMenu(menu, with: event, for: view)
        menuOpen = false
        scheduleSettle(after: 0.25)
    }

    func open(_ targets: [ShelfItem]) {
        let urls = current(targets).flatMap(\.files).filter(\.isAvailable).map(\.url)
        guard !urls.isEmpty else { return NSSound.beep() }
        urls.forEach { NSWorkspace.shared.open($0) }
    }

    /// Finder で表示（参照は元の場所、コピーは棚の中の場所）
    func reveal(_ targets: [ShelfItem]) {
        let urls = current(targets).flatMap(\.files).filter(\.isAvailable).map(\.url)
        guard !urls.isEmpty else { return NSSound.beep() }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// 場所を確かめ直した、いまの項目（元のファイルがあとから動いていても、その先を開けるように）
    private func current(_ targets: [ShelfItem]) -> [ShelfItem] {
        let ids = targets.map(\.id)
        refreshItems(ids)
        return items.filter { ids.contains($0.id) }
    }

    private func action(_ title: String, enabled: Bool = true, _ handler: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, handler: handler)
        item.isEnabled = enabled
        return item
    }
}

// MARK: - 項目の見せ方

extension ShelfItem {
    /// 受け口のアイコンと項目の印（同じ形にして、どちらで置いたかを覚えやすくする）
    static func symbol(for mode: ShelfDropMode) -> String {
        mode == .copy ? "doc.on.doc.fill" : "link"
    }

    static func color(for mode: ShelfDropMode) -> NSColor {
        mode == .copy ? NSColor(srgbRed: 0.2, green: 0.78, blue: 0.45, alpha: 1) // 緑（コピーの「+」と同じ系統）
                      : NSColor(srgbRed: 0.3, green: 0.6, blue: 1, alpha: 1)     // 青（リンク）
    }

    /// 右下の印。メモには付けない（付箋の見た目でわかる）。まとめは、見つからないファイルが 1 つでもあれば知らせる
    var badge: (symbol: String, color: NSColor)? {
        if isGroup, missingCount > 0, status != .copying { return ("exclamationmark", .systemOrange) }
        switch (kind, status) {
        case (_, .missing): return ("exclamationmark", .systemOrange)
        case (_, .trashed): return ("trash.fill", .systemOrange)
        case (.memo, _): return nil
        case (.copy, _): return (Self.symbol(for: .copy), Self.color(for: .copy))
        case (.reference, _): return (Self.symbol(for: .reference), Self.color(for: .reference))
        }
    }

    /// 右クリックメニューの先頭に出す、どう置いたものかの一言
    var summary: String {
        if isGroup {
            let how = status == .copying ? L("棚にコピーしています…", "copying to the shelf…")
                : kind == .copy ? L("棚の中のコピー", "copies on the shelf") : L("参照", "references")
            let missing = missingCount > 0 ? L("。\(missingCount) 個が見つかりません", "; \(missingCount) not found") : ""
            return L("\(files.count) 項目のまとめ（\(how)\(missing)）", "Stack of \(files.count) items (\(how)\(missing))")
        }
        switch (kind, status) {
        case (.memo, _): return L("メモ", "Note")
        case (_, .copying): return L("棚にコピーしています…", "Copying to the shelf…")
        case (.reference, .missing): return L("元のファイルが見つかりません", "Original file not found")
        case (.reference, .trashed): return L("元のファイルはゴミ箱の中です", "The original is in the Trash")
        case (.reference, _): return L("参照（元の場所：\(Self.folderName(of: url))）", "Reference (in \(Self.folderName(of: url)))")
        case (.copy, .missing): return L("棚の中のコピーが見つかりません", "The copy on the shelf is missing")
        case (.copy, _):
            guard let sourceURL else { return L("棚の中のファイル（貼り付け）", "File on the shelf (pasted)") }
            return L("棚の中のコピー（元の場所：\(Self.folderName(of: sourceURL))）", "Copy on the shelf (from \(Self.folderName(of: sourceURL)))")
        }
    }

    /// ツールチップ。場所と、外へドラッグしたらどうなるか
    var tooltip: String {
        if isGroup {
            let names = files.prefix(6).map(\.url.lastPathComponent).joined(separator: "\n")
            let more = files.count > 6 ? L("\nほか \(files.count - 6) 項目", "\nand \(files.count - 6) more") : ""
            let how = kind == .copy
                ? L("外へドラッグすると、まとめて棚の複製が移動します。元のファイルはそのまま",
                    "Dragging it out moves all the shelf’s copies; the originals stay untouched.")
                : L("外へドラッグすると、まとめて元のファイルが移動します", "Dragging it out moves all the original files.")
            return "\(summary)\n\(names)\(more)\n\(how)"
        }
        let path = Self.tilde(url)
        switch (kind, status) {
        case (.memo, _):
            return L("メモ（クリックで編集。外へドラッグすると .txt を書き出し、棚にも残ります）",
                     "Note (click to edit; dragging it out exports a .txt file and keeps the note on the shelf)")
        case (_, .copying):
            return L("棚にコピーしています…", "Copying to the shelf…")
        case (.reference, .missing):
            return L("元のファイルが見つかりません（最後にあった場所：\(path)）", "Original file not found (last seen at \(path))")
        case (.reference, .trashed):
            return L("元のファイルはゴミ箱の中です", "The original is in the Trash")
        case (.reference, _):
            return L("参照：\(path)\n外へドラッグすると、元のファイルが移動します（⌥を押しながらなら、行き先に複製を置いて棚にも残します）",
                     "Reference: \(path)\nDragging it out moves the original (hold ⌥ to place a copy and keep it on the shelf).")
        case (.copy, .missing):
            return L("棚の中のコピーが見つかりません", "The copy on the shelf is missing")
        case (.copy, _):
            let from = sourceURL.map { L("元：\(Self.tilde($0))", "from \(Self.tilde($0))") } ?? L("貼り付けたもの", "pasted")
            return L("棚の中のコピー（\(from)）\n外へドラッグすると、このコピーが移動します。元のファイルには触りません（⌥を押しながらなら棚にも残します）",
                     "Copy on the shelf (\(from))\nDragging it out moves this copy; the original stays untouched (hold ⌥ to keep it on the shelf too).")
        }
    }

    private static func tilde(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    /// 入っているフォルダの名前（Finder と同じ表示名。例: 書類、デスクトップ）
    private static func folderName(of url: URL) -> String {
        FileManager.default.displayName(atPath: url.deletingLastPathComponent().path)
    }
}
