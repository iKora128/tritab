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
}

// MARK: - ドラッグの決まり

@Suite struct ShelfRulesTests {
    @Test func leftHalfCopiesAndRightHalfReferences() {
        #expect(ShelfRules.dropMode(atX: 10, shelfMinX: 0, shelfMaxX: 400) == .copy)
        #expect(ShelfRules.dropMode(atX: 199, shelfMinX: 0, shelfMaxX: 400) == .copy)
        #expect(ShelfRules.dropMode(atX: 200, shelfMinX: 0, shelfMaxX: 400) == .reference)
        #expect(ShelfRules.dropMode(atX: 1100, shelfMinX: 800, shelfMaxX: 1200) == .reference)
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
        #expect(ShelfRules.dragOutOperations(for: .copy) == [.copy, .generic, .move]) // 棚の中の複製へのエイリアスは作らせない
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
