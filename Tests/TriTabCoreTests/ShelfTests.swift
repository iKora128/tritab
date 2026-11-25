import Foundation
import Testing
@testable import TriTabCore

// MARK: - 選択

@Suite struct ShelfSelectionTests {
    let order = ["a", "b", "c", "d", "e"]

    @Test func plainClickSelectsOnlyThatItem() {
        var s = ShelfSelection<String>()
        s.click("b", in: order)
        #expect(s.ids == ["b"])
        s.click("d", in: order)
        #expect(s.ids == ["d"])
    }

    @Test func plainClickOnASelectedItemKeepsTheGroupForDragging() {
        var s = ShelfSelection<String>()
        s.click("a", in: order)
        s.click("c", in: order, command: true)
        s.click("c", in: order) // 押した時点では選び直さない（まとめてドラッグできるように）
        #expect(s.ids == ["a", "c"])
        #expect(s.dragItems(from: "c", in: order) == ["a", "c"])
        s.select("c") // ドラッグせずに離したら、その項目だけを選び直す
        #expect(s.ids == ["c"])
    }

    @Test func commandClickToggles() {
        var s = ShelfSelection<String>()
        s.click("a", in: order)
        s.click("c", in: order, command: true)
        #expect(s.ids == ["a", "c"])
        s.click("a", in: order, command: true)
        #expect(s.ids == ["c"])
    }

    @Test func shiftClickSelectsARangeFromTheAnchor() {
        var s = ShelfSelection<String>()
        s.click("b", in: order)
        s.click("d", in: order, shift: true)
        #expect(s.ids == ["b", "c", "d"])
        s.click("a", in: order, shift: true) // 起点より前へも広げられる
        #expect(s.ids == ["a", "b", "c", "d"])
    }

    @Test func shiftClickWithoutAnAnchorAddsJustThatItem() {
        var s = ShelfSelection<String>()
        s.click("c", in: order, shift: true)
        #expect(s.ids == ["c"])
    }

    @Test func selectAllAndClear() {
        var s = ShelfSelection<String>()
        s.selectAll(order)
        #expect(s.count == 5)
        #expect(s.dragItems(from: "e", in: order) == order)
        s.clear()
        #expect(s.isEmpty)
    }

    @Test func draggingAnUnselectedItemTakesOnlyThatItem() {
        var s = ShelfSelection<String>()
        s.selectAll(["a", "b"])
        #expect(s.dragItems(from: "d", in: order) == ["d"])
    }

    @Test func removedItemsLeaveTheSelection() {
        var s = ShelfSelection<String>()
        s.click("b", in: order)
        s.click("d", in: order, command: true)
        s.keep(["a", "b", "c"])
        #expect(s.ids == ["b"])
        // 起点（d）が消えたので、⇧クリックは範囲にならない
        s.keep(["a", "c"])
        s.click("c", in: ["a", "c"], shift: true)
        #expect(s.ids == ["c"])
    }

    // 1 段に 3 つ並ぶとき: [a b c] / [d e]。
    // #expect の中では mutating のメソッドを呼べないので、押す操作は press にまとめる

    @Test func arrowKeysMoveTheSelectionToTheNeighbor() {
        var s = ShelfSelection<String>()
        func press(_ d: ShelfSelection<String>.Direction) -> Bool { s.move(d, in: order, columns: 3) }
        s.click("b", in: order)
        #expect(press(.right))
        #expect(s.ids == ["c"])
        #expect(press(.left))
        #expect(press(.left))
        #expect(s.ids == ["a"])
        #expect(!press(.left)) // 端ではそれ以上動かない
        #expect(s.ids == ["a"])
    }

    @Test func upAndDownMoveByARow() {
        var s = ShelfSelection<String>()
        func press(_ d: ShelfSelection<String>.Direction) -> Bool { s.move(d, in: order, columns: 3) }
        s.select("b")
        #expect(press(.down))
        #expect(s.ids == ["e"])
        #expect(press(.up))
        #expect(s.ids == ["b"])
        #expect(!press(.up)) // 上の段はない
        s.select("c")
        #expect(press(.down)) // 真下に項目がなければ、最後の項目へ（Finder と同じ）
        #expect(s.ids == ["e"])
        #expect(!press(.down))
    }

    @Test func arrowWithNothingSelectedStartsFromTheHoveredItemOrTheEnd() {
        var s = ShelfSelection<String>()
        func press(_ d: ShelfSelection<String>.Direction, start: String? = nil) -> Bool {
            s.move(d, in: order, columns: 3, start: start)
        }
        #expect(press(.right))
        #expect(s.ids == ["a"])
        s.clear()
        #expect(press(.left))
        #expect(s.ids == ["e"])
        s.clear()
        #expect(press(.down, start: "c")) // マウスが乗っている項目から
        #expect(s.ids == ["c"])
        var empty = ShelfSelection<String>()
        func pressOnEmpty() -> Bool { empty.move(.right, in: [], columns: 3) }
        #expect(!pressOnEmpty())
    }

    @Test func shiftArrowExtendsFromTheAnchor() {
        var s = ShelfSelection<String>()
        func press(_ d: ShelfSelection<String>.Direction, extend: Bool = false) -> Bool {
            s.move(d, in: order, columns: 3, extend: extend)
        }
        s.select("b")
        #expect(press(.right, extend: true))
        #expect(s.ids == ["b", "c"])
        #expect(press(.down, extend: true))
        #expect(s.ids == ["b", "c", "d", "e"])
        #expect(press(.up, extend: true)) // 起点（b）まで戻ると、b だけになる
        #expect(s.ids == ["b"])
        #expect(press(.left, extend: true)) // 起点の反対側へも広げられる
        #expect(s.ids == ["a", "b"])
        #expect(press(.right)) // ⇧なしなら、今の位置（a）の隣だけを選ぶ
        #expect(s.ids == ["b"])
    }

    @Test func arrowContinuesFromTheLastClickedItem() {
        var s = ShelfSelection<String>()
        func press(_ d: ShelfSelection<String>.Direction) -> Bool { s.move(d, in: order, columns: 3) }
        s.click("a", in: order)
        s.click("d", in: order, command: true)
        #expect(press(.right))
        #expect(s.ids == ["e"])
        s.selectAll(order)
        #expect(press(.left))
        #expect(s.ids == ["d"])
    }
}

// MARK: - まとめ

@Suite struct ShelfGroupTests {
    private func file(_ name: String, _ kind: ShelfItem.Kind = .reference, _ status: ShelfItem.Status = .ready) -> ShelfItem {
        ShelfItem(kind: kind, url: URL(fileURLWithPath: "/tmp/\(name)"), status: status)
    }

    @Test func oneDropOfSeveralFilesBecomesOneItem() {
        let a = file("a.png"), b = file("b.png"), c = file("c.png")
        let group = ShelfItem.group([a, b, c])
        #expect(group.isGroup)
        #expect(group.files.map(\.id) == [a.id, b.id, c.id])
        #expect(group.kind == .reference)
        #expect(group.url == a.url) // 見た目と名前は先頭のファイル
        // 1 つだけなら、まとめにしない
        #expect(ShelfItem.group([a]) == a)
    }

    @Test func groupIsUsableWhileAnyFileIsThere() {
        var group = ShelfItem.group([file("a"), file("b", .reference, .missing)])
        #expect(group.isAvailable)
        #expect(group.missingCount == 1)
        #expect(group.keepingAvailableFiles().files.count == 1) // 持ち出すのは見つかるものだけ
        group.setStatus(.missing, ofFile: group.members[0].id)
        #expect(!group.isAvailable)
        #expect(group.status == .missing)
    }

    @Test func groupWaitsForAllCopies() {
        var group = ShelfItem.group([file("a", .copy, .copying), file("b", .copy, .copying)])
        #expect(group.status == .copying)
        group.setStatus(.ready, ofFile: group.members[0].id)
        #expect(group.status == .copying)
        group.setStatus(.ready, ofFile: group.members[1].id)
        #expect(group.status == .ready)
    }

    @Test func removingFilesShrinksTheGroup() {
        let a = file("a"), b = file("b"), c = file("c")
        let group = ShelfItem.group([a, b, c])
        #expect(group.removingFiles([b.id])?.files.map(\.id) == [a.id, c.id])
        #expect(group.removingFiles([b.id])?.id == group.id)
        #expect(group.removingFiles([a.id, b.id]) == c) // 1 つだけ残ったら、ふつうの項目に戻る
        #expect(group.removingFiles([a.id, b.id, c.id]) == nil)
        #expect(a.removingFiles([a.id]) == nil)
        #expect(a.removingFiles([b.id]) == a)
    }

    @Test func groupIsAsNewAsItsNewestFile() {
        let old = ShelfItem(kind: .copy, url: URL(fileURLWithPath: "/tmp/a"), addedAt: Date(timeIntervalSince1970: 100))
        let new = ShelfItem(kind: .copy, url: URL(fileURLWithPath: "/tmp/b"), addedAt: Date(timeIntervalSince1970: 200))
        let group = ShelfItem.group([old, new])
        #expect(group.addedAt == Date(timeIntervalSince1970: 200))
        // 新しいほうが出ていったら、残ったファイルの日時になる
        #expect(group.removingFiles([new.id])?.addedAt == Date(timeIntervalSince1970: 100))
    }

    @Test func receivedFileReplacesItsPlaceholder() {
        // ブラウザから届くファイルは、名前が届くまでわからない
        var group = ShelfItem.group([file("受け取り中", .copy, .copying), file("受け取り中", .copy, .copying)])
        let first = group.members[0].id
        group.updateFile(first) { $0.url = URL(fileURLWithPath: "/tmp/photo.jpg") }
        group.setStatus(.ready, ofFile: first)
        #expect(group.url.lastPathComponent == "photo.jpg") // 見た目と名前は先頭のファイル
        #expect(group.status == .copying) // もう 1 つはまだ
        var single = file("受け取り中", .copy, .copying)
        single.updateFile(single.id) { $0.url = URL(fileURLWithPath: "/tmp/cat.gif") }
        #expect(single.url.lastPathComponent == "cat.gif")
    }
}

// MARK: - ドラッグの決まり

@Suite struct ShelfRulesTests {
    @Test func switchDecidesTheDropModeAndModifiersOverrideIt() {
        // ふだんはスイッチの置き方
        #expect(ShelfRules.dropMode(default: .reference, option: false, command: false) == .reference)
        #expect(ShelfRules.dropMode(default: .copy, option: false, command: false) == .copy)
        // ⌥ はコピー、⌘⌥ は参照（Finder と同じ）。⌘ だけでは変わらない
        #expect(ShelfRules.dropMode(default: .reference, option: true, command: false) == .copy)
        #expect(ShelfRules.dropMode(default: .copy, option: true, command: true) == .reference)
        #expect(ShelfRules.dropMode(default: .copy, option: false, command: true) == .copy)
    }

    @Test func cursorShowsCopyOrAlias() {
        let finder: ShelfDragOperation = [.copy, .link, .generic, .move]
        #expect(ShelfRules.dropOperation(for: .copy, sourceAllows: finder) == .copy)
        #expect(ShelfRules.dropOperation(for: .reference, sourceAllows: finder) == .link)
        // ⌥を押しているとコピーしか許されない
        #expect(ShelfRules.dropOperation(for: .reference, sourceAllows: .copy) == .copy)
        #expect(ShelfRules.dropOperation(for: .reference, sourceAllows: [.copy, .generic]) == .generic)
        // ドラッグ元が移動しか許さなくても、.move は返さない
        #expect(ShelfRules.dropOperation(for: .copy, sourceAllows: .move) == [])
    }

    @Test func dragOutOperationsDependOnTheKind() {
        #expect(ShelfRules.dragOutOperations(for: .reference) == [.copy, .link, .generic, .move])
        #expect(ShelfRules.dragOutOperations(for: .copy) == [.copy, .generic, .move]) // トレイの中の複製へのエイリアスは作らせない
        #expect(ShelfRules.dragOutOperations(for: .memo) == .copy)
        // まとめてドラッグするときは、全部に共通する操作だけ
        #expect(ShelfRules.dragOutOperations(for: [.reference, .copy]) == [.copy, .generic, .move])
        #expect(ShelfRules.dragOutOperations(for: [.reference, .memo]) == .copy)
    }

    @Test func onlyMovedItemsLeaveTheShelf() {
        #expect(!ShelfRules.staysOnShelf(.reference, after: .move))
        #expect(!ShelfRules.staysOnShelf(.copy, after: .generic))
        // ⌥でコピーした・別のディスクへコピーされた・メールに添付した・エイリアスを作った・置けなかった
        #expect(ShelfRules.staysOnShelf(.reference, after: .copy))
        #expect(ShelfRules.staysOnShelf(.copy, after: .copy))
        #expect(ShelfRules.staysOnShelf(.reference, after: .link))
        #expect(ShelfRules.staysOnShelf(.copy, after: []))
        // メモはいつも残る
        #expect(ShelfRules.staysOnShelf(.memo, after: .move))
    }

    @Test func dropsAreReadInTheOrderThatKeepsTheMost() {
        func content(files: Bool = false, promises: Bool = false, image: Bool = false, link: Bool = false, text: Bool = false) -> ShelfDropContent? {
            ShelfRules.dropContent(fileURLs: files, promisedFiles: promises, image: image, link: link, text: text)
        }
        // Finder のファイルは、パスの文字なども一緒に持っている
        #expect(content(files: true, image: true, link: true, text: true) == .files)
        // ブラウザの画像は、画像の URL や画像のデータも持っている。元のファイルの形のまま受け取る
        #expect(content(promises: true, image: true, link: true, text: true) == .promisedFiles)
        #expect(content(image: true, link: true, text: true) == .image)
        // リンクは、URL の文字も持っている
        #expect(content(link: true, text: true) == .link)
        #expect(content(text: true) == .text)
        #expect(content() == nil)
    }

    @Test func linksAndTextWaitForTheNotch() {
        #expect(ShelfDropContent.files.opensOnApproach)
        #expect(ShelfDropContent.promisedFiles.opensOnApproach)
        #expect(ShelfDropContent.image.opensOnApproach)
        // タブやテキストのドラッグは画面の上のほうでもよくするので、上へ動かしただけでは開かない
        #expect(!ShelfDropContent.link.opensOnApproach)
        #expect(!ShelfDropContent.text.opensOnApproach)
    }

    @Test func shelfPeeksWhenRisingAndOpensNearTheTop() {
        let area = ShelfReceiveArea(depth: 320, halfWidth: 500)
        // 下のほうで上へ動かすと、顔を出す
        #expect(ShelfRules.approach(fromTop: 600, fromCenter: 0, risen: 30, area: area) == .peek)
        #expect(ShelfRules.approach(fromTop: 600, fromCenter: 0, risen: 10, area: area) == .none)
        // 上端の真ん中のまわりに来たら、広げる
        #expect(ShelfRules.approach(fromTop: 300, fromCenter: 450, risen: 30, area: area) == .open)
        // 横長の画面の端のほうなら、上端まで来ても広げない
        #expect(ShelfRules.approach(fromTop: 100, fromCenter: 900, risen: 300, area: area) == .peek)
        // 上のほうでドラッグを始めただけ（Finder の中で動かしているなど）では開かない
        #expect(ShelfRules.approach(fromTop: 150, fromCenter: 0, risen: 0, area: area) == .none)
        // ノッチのすぐ近くなら、上へ動かしていなくても開く
        #expect(ShelfRules.approach(fromTop: 40, fromCenter: 100, risen: 0, area: area) == .open)
    }

    @Test func shelfOpensByPositionOnly() {
        let area = ShelfReceiveArea(depth: 320, halfWidth: 500)
        // 範囲の手前では、どれだけ上へ動かしても広げない（速さでは決めない）
        #expect(ShelfRules.approach(fromTop: 330, fromCenter: 0, risen: 800, area: area) == .peek)
        #expect(ShelfRules.approach(fromTop: 310, fromCenter: 0, risen: 800, area: area) == .open)
    }

    @Test func openedShelfRetractsOnlyWhenFarFromTheArea() {
        let area = ShelfReceiveArea(depth: 320, halfWidth: 500)
        // 範囲から 150 より離れたら引っ込める（下へも、横へも）
        #expect(ShelfRules.shouldRetract(fromTop: 480, fromCenter: 0, area: area))
        #expect(ShelfRules.shouldRetract(fromTop: 100, fromCenter: 660, area: area))
        // 範囲を少し出たくらいなら、止まっていても引っ込めない（トラックパッドで指を置き直しても開いたり閉じたりしない）
        #expect(!ShelfRules.shouldRetract(fromTop: 460, fromCenter: 0, area: area))
        #expect(!ShelfRules.shouldRetract(fromTop: 100, fromCenter: 640, area: area))
        #expect(!ShelfRules.shouldRetract(fromTop: 200, fromCenter: 0, area: area))
    }

    @Test func expiredItemsAreTheOldOnesOldestFirst() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let day: TimeInterval = 24 * 60 * 60
        func item(daysAgo: Double, _ status: ShelfItem.Status = .ready) -> ShelfItem {
            ShelfItem(kind: .copy, url: URL(fileURLWithPath: "/tmp/x"), status: status, addedAt: now.addingTimeInterval(-daysAgo * day))
        }
        let fresh = item(daysAgo: 1), old = item(daysAgo: 8), older = item(daysAgo: 30), copying = item(daysAgo: 9, .copying)
        #expect(ShelfRules.expired([fresh, old, copying, older], olderThan: 7 * day, now: now) == [older.id, old.id])
        // ちょうどその期間がたったものも削除する
        #expect(ShelfRules.expired([item(daysAgo: 7)], olderThan: 7 * day, now: now).count == 1)
    }

    @Test func temporaryFilesAreRecognized() {
        let home = URL(fileURLWithPath: "/Users/someone")
        #expect(ShelfRules.isTemporary(URL(fileURLWithPath: "/private/var/folders/ab/cd/T/screenshot.png"), home: home))
        #expect(ShelfRules.isTemporary(URL(fileURLWithPath: "/var/folders/ab/cd/T/screenshot.png"), home: home))
        #expect(ShelfRules.isTemporary(URL(fileURLWithPath: "/tmp/drag/file.txt"), home: home))
        #expect(ShelfRules.isTemporary(URL(fileURLWithPath: "/Users/someone/Library/Caches/com.example/drag.pdf"), home: home))
        #expect(!ShelfRules.isTemporary(URL(fileURLWithPath: "/Users/someone/Desktop/report.pdf"), home: home))
        #expect(!ShelfRules.isTemporary(URL(fileURLWithPath: "/Users/someone/Library/CachesBackup/a.txt"), home: home))
    }
}

// MARK: - 保存とコピーの置き場所

/// 比べるためのパス（一時フォルダは /var と /private/var の両方の書き方で返ってくるため、そろえる）
private func path(_ url: URL) -> String {
    let p = url.standardizedFileURL.path
    return p.hasPrefix("/private/") ? String(p.dropFirst("/private".count)) : p
}

/// テストごとの作業フォルダ。ゴミ箱へ移す処理は、本物のゴミ箱を使わずに記録して消すだけにする
private final class Sandbox {
    let root: URL
    private(set) var trashed: [URL] = []
    private(set) lazy var library = ShelfLibrary(
        directory: root.appendingPathComponent("Support/Shelf"),
        memoDirectory: root.appendingPathComponent("Support/Memos"),
        trash: { [unowned self] url in
            self.trashed.append(url)
            try? FileManager.default.removeItem(at: url)
        })

    init() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("TriTabShelfTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func file(_ name: String, _ text: String = "hello", in folder: String = "Documents") -> URL {
        let dir = root.appendingPathComponent(folder)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try! text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func readyCopy(of url: URL) throws -> ShelfItem {
        var item = library.plannedCopy(of: url)
        try ShelfLibrary.copy(from: url, to: item.url)
        item.status = .ready
        return item
    }
}

@Suite struct ShelfLibraryTests {
    @Test func referenceFollowsTheOriginalWhenItMoves() throws {
        let box = Sandbox()
        let original = box.file("report.pdf")
        var item = box.library.reference(to: original)
        #expect(item.bookmark != nil)
        let moved = box.root.appendingPathComponent("Desktop/renamed.pdf")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: original, to: moved)

        box.library.refresh(&item)
        #expect(item.status == .ready)
        #expect(path(item.url) == path(moved))
    }

    @Test func referenceIsMarkedWhenTheOriginalIsGone() throws {
        let box = Sandbox()
        let original = box.file("a.txt")
        var item = box.library.reference(to: original)
        try FileManager.default.removeItem(at: original)
        #expect(box.library.refresh(&item))
        #expect(item.status == .missing)
        #expect(!item.isAvailable)
    }

    @Test func quickRefreshOnlyChecksThatTheFileIsStillThere() throws {
        let box = Sandbox()
        let original = box.file("a.txt")
        // ブックマークがなくても、いまの場所にあれば使える（つかんだ瞬間にブックマークを解決しない）
        var reference = ShelfItem(kind: .reference, url: original)
        #expect(!box.library.quickRefresh(&reference))
        #expect(reference.isAvailable)
        // コピーが消えていれば、見つからない
        var copy = try box.readyCopy(of: box.file("b.txt"))
        try FileManager.default.removeItem(at: copy.url)
        #expect(box.library.quickRefresh(&copy))
        #expect(copy.status == .missing)
        // 作っている途中のコピーには触らない
        var planned = box.library.plannedCopy(of: original)
        #expect(!box.library.quickRefresh(&planned))
        #expect(planned.status == .copying)
    }

    @Test func quickRefreshFollowsAReferenceThatMoved() throws {
        let box = Sandbox()
        let original = box.file("report.pdf")
        var item = box.library.reference(to: original)
        let moved = box.root.appendingPathComponent("Desktop/report.pdf")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: original, to: moved)
        // いまの場所に見つからないときだけ、ブックマークで追い直す
        #expect(box.library.quickRefresh(&item))
        #expect(item.status == .ready)
        #expect(path(item.url) == path(moved))
    }

    @Test func referenceInTheTrashIsMarked() throws {
        let box = Sandbox()
        let original = box.file("a.txt")
        var item = box.library.reference(to: original)
        let trash = box.root.appendingPathComponent(".Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: original, to: trash.appendingPathComponent("a.txt"))
        box.library.refresh(&item)
        #expect(item.status == .trashed)
    }

    @Test func copyIsIndependentOfTheOriginal() throws {
        let box = Sandbox()
        let original = box.file("photo.png", "v1")
        let planned = box.library.plannedCopy(of: original)
        #expect(planned.kind == .copy)
        #expect(planned.status == .copying)
        #expect(planned.url.lastPathComponent == "photo.png") // 外へ出すときも元の名前のまま

        let item = try box.readyCopy(of: original)
        try "v2".write(to: original, atomically: true, encoding: .utf8)
        #expect(try String(contentsOf: item.url, encoding: .utf8) == "v1")
        #expect(FileManager.default.fileExists(atPath: original.path))
        // 同じ名前のコピーを重ねて作ってもぶつからない
        #expect(planned.url != item.url)
    }

    @Test func savedShelfComesBackInOrder() throws {
        let box = Sandbox()
        let ref = box.library.reference(to: box.file("a.txt"))
        let copy = try box.readyCopy(of: box.file("b.txt"))
        let pasted = try #require(box.library.store(Data("png".utf8), name: "Image.png"))
        box.library.save([copy, ref, pasted])

        let loaded = box.library.load()
        #expect(loaded.map(\.id) == [copy.id, ref.id, pasted.id])
        #expect(loaded.map(\.kind) == [.copy, .reference, .copy])
        #expect(loaded.allSatisfy { $0.status == .ready })
        #expect(loaded[0].sourceURL?.lastPathComponent == "b.txt")
        #expect(loaded[2].sourceURL == nil)
    }

    @Test func unfinishedCopiesAndStrayFoldersAreCleanedUp() throws {
        let box = Sandbox()
        // 作っている途中で終了した
        let unfinished = box.library.plannedCopy(of: box.file("big.mov"))
        try ShelfLibrary.copy(from: unfinished.sourceURL!, to: unfinished.url)
        // 一覧にないフォルダ: 外へ移動されて空になったものと、中身が残ったもの
        try FileManager.default.createDirectory(at: box.library.copiesDirectory.appendingPathComponent(UUID().uuidString),
                                                withIntermediateDirectories: true)
        let leftover = try box.readyCopy(of: box.file("left.txt"))
        box.library.save([unfinished])

        #expect(box.library.load().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: box.library.copiesDirectory.path).isEmpty)
        // 中身が残っていたものはゴミ箱へ。作りかけは消すだけ
        #expect(box.trashed.map(path) == [path(leftover.url)])
    }

    @Test func groupComesBackWithItsFiles() throws {
        let box = Sandbox()
        let refs = ShelfItem.group([box.library.reference(to: box.file("a.txt")), box.library.reference(to: box.file("b.txt"))])
        let copies = ShelfItem.group([try box.readyCopy(of: box.file("c.png")), try box.readyCopy(of: box.file("d.png"))])
        box.library.save([refs, copies])

        let loaded = box.library.load()
        #expect(loaded.map(\.id) == [refs.id, copies.id])
        #expect(loaded.map(\.files.count) == [2, 2])
        #expect(loaded[1].kind == .copy)
        #expect(loaded.allSatisfy { $0.isAvailable })
        // まとめの中のコピーは、片付けで消されない
        #expect(loaded[1].files.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
        #expect(box.trashed.isEmpty)
    }

    @Test func groupWithAMissingFileStaysUsable() throws {
        let box = Sandbox()
        let gone = box.file("gone.txt")
        var group = ShelfItem.group([box.library.reference(to: box.file("a.txt")), box.library.reference(to: gone)])
        try FileManager.default.removeItem(at: gone)
        box.library.refresh(&group)
        #expect(group.isAvailable)
        #expect(group.missingCount == 1)
    }

    @Test func unfinishedCopyInAGroupIsDropped() throws {
        let box = Sandbox()
        let done = try box.readyCopy(of: box.file("a.png"))
        let unfinished = box.library.plannedCopy(of: box.file("b.png"))
        box.library.save([ShelfItem.group([done, unfinished])])

        // 作りかけを捨てて 1 つになったので、ふつうの項目に戻る
        let loaded = box.library.load()
        #expect(loaded.map(\.id) == [done.id])
        #expect(!loaded[0].isGroup)
    }

    @Test func discardingAGroupTrashesItsCopies() throws {
        let box = Sandbox()
        let a = try box.readyCopy(of: box.file("a.png"))
        let b = try box.readyCopy(of: box.file("b.png"))
        box.library.discard(ShelfItem.group([a, b]))
        #expect(Set(box.trashed.map(path)) == Set([path(a.url), path(b.url)]))
    }

    @Test func memosFromEarlierVersionsAreKept() throws {
        let box = Sandbox()
        let memos = box.library.memoDirectory
        try FileManager.default.createDirectory(at: memos, withIntermediateDirectories: true)
        try "b".write(to: memos.appendingPathComponent("メモ 2026-11-02.txt"), atomically: true, encoding: .utf8)
        try "a".write(to: memos.appendingPathComponent("メモ 2026-11-01.txt"), atomically: true, encoding: .utf8)

        // shelf.json がない（0.1.0 から上げたとき）
        let loaded = box.library.load()
        #expect(loaded.map(\.kind) == [.memo, .memo])
        #expect(loaded.map(\.url.lastPathComponent) == ["メモ 2026-11-01.txt", "メモ 2026-11-02.txt"])
        // 一覧に入ったメモは二重にならず、並び順も保つ
        box.library.save(loaded.reversed())
        #expect(box.library.load().map(\.url.lastPathComponent) == ["メモ 2026-11-02.txt", "メモ 2026-11-01.txt"])
    }

    @Test func discardTrashesTheCopyButNeverTouchesTheOriginal() throws {
        let box = Sandbox()
        let original = box.file("a.txt")
        let ref = box.library.reference(to: original)
        let copy = try box.readyCopy(of: original)

        box.library.discard(ref)
        box.library.discard(copy)
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(box.trashed.map(path) == [path(copy.url)])
        #expect(!FileManager.default.fileExists(atPath: copy.url.deletingLastPathComponent().path))
    }

    @Test func linkIsSavedAsAWeblocNamedAfterItsTitle() throws {
        let box = Sandbox()
        let url = try #require(URL(string: "https://example.com/articles/42?ref=top"))
        let item = try #require(box.library.storeLink(url, title: "Swift: 入門 / 第1回\n"))
        #expect(item.kind == .copy)
        #expect(item.url.lastPathComponent == "Swift- 入門 - 第1回.webloc") // ファイル名に使えない文字は置き換える
        #expect(ShelfLibrary.linkTarget(of: item.url) == url)
        // 題名がなければサイトの名前
        let untitled = try #require(box.library.storeLink(url, title: nil))
        #expect(untitled.url.lastPathComponent == "example.com.webloc")
        #expect(try #require(box.library.storeLink(url, title: "   ")).url.lastPathComponent == "example.com.webloc")
        // ほかのファイルはリンクとして読まない
        #expect(ShelfLibrary.linkTarget(of: box.file("a.txt")) == nil)
    }

    @Test func addedDateComesBackAfterRestart() throws {
        let box = Sandbox()
        let added = Date(timeIntervalSince1970: 1_700_000_000)
        var copy = try box.readyCopy(of: box.file("a.txt"))
        copy.addedAt = added
        let group = ShelfItem.group([box.library.reference(to: box.file("b.txt")), box.library.reference(to: box.file("c.txt"))])
        box.library.save([copy, group])

        let loaded = box.library.load(now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(loaded[0].addedAt == added)
        #expect(loaded[1].addedAt == group.addedAt)
    }

    @Test func itemsFromEarlierVersionsAreDatedWhenFirstLoaded() throws {
        let box = Sandbox()
        // 0.1.1 までの一覧（置いた日時がない）
        let file = box.file("a.txt")
        let record = #"[{"id":"\#(UUID().uuidString)","kind":"reference","path":"\#(file.path)"}]"#
        try FileManager.default.createDirectory(at: box.library.directory, withIntermediateDirectories: true)
        try Data(record.utf8).write(to: box.library.directory.appendingPathComponent("shelf.json"))

        let firstLoad = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(box.library.load(now: firstLoad).map(\.addedAt) == [firstLoad])
        // 読み込んだ時点を置いた日時として保存してあるので、次に読み込んでも変わらない（いつまでも新しいままにならない）
        #expect(box.library.load(now: firstLoad.addingTimeInterval(3600)).map(\.addedAt) == [firstLoad])
    }

    @Test func movedCopyLeavesNoEmptyFolder() throws {
        let box = Sandbox()
        let copy = try box.readyCopy(of: box.file("a.txt"))
        // Finder が行き先へ移動した
        try FileManager.default.moveItem(at: copy.url, to: box.root.appendingPathComponent("moved.txt"))
        box.library.cleanUpAfterMove(copy)
        #expect(!FileManager.default.fileExists(atPath: copy.url.deletingLastPathComponent().path))
        #expect(box.trashed.isEmpty)
    }
}
