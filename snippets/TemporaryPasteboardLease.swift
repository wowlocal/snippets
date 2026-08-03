import AppKit

/// The slice of `NSPasteboard` the lease uses. It exists so a test harness can stand in a fake.
@MainActor
protocol SnippetPasteboardAccess: AnyObject {
    var changeCount: Int { get }
    var pasteboardItems: [NSPasteboardItem]? { get }
    @discardableResult func clearContents() -> Int
    func writeObjects(_ objects: [any NSPasteboardWriting]) -> Bool
}

extension NSPasteboard: SnippetPasteboardAccess {}

/// The pasteboard exactly as it was: item order, type order within an item, bytes.
/// `items == nil` is not `items == []` — "we could not read it" and "it is empty" restore differently.
@MainActor
struct PasteboardSnapshot {
    struct Item {
        let values: [(type: NSPasteboard.PasteboardType, data: Data)]
    }

    let items: [Item]?
    let changeCount: Int

    var isUnavailable: Bool { items == nil }

    init(reading pasteboard: any SnippetPasteboardAccess) {
        let changeCount = pasteboard.changeCount
        var captured: [Item] = []
        for pasteboardItem in pasteboard.pasteboardItems ?? [] {
            var values: [(type: NSPasteboard.PasteboardType, data: Data)] = []
            for type in pasteboardItem.types {
                // A type we cannot read would silently vanish from the "restored" clipboard, so the
                // whole snapshot is unusable instead.
                guard let data = pasteboardItem.data(forType: type) else {
                    self.items = nil
                    self.changeCount = changeCount
                    return
                }
                values.append((type: type, data: data))
            }
            captured.append(Item(values: values))
        }
        // A snapshot spanning two different clipboard states is worse than none.
        self.items = pasteboard.changeCount == changeCount ? captured : nil
        self.changeCount = changeCount
    }

    var firstStringData: Data? {
        items?.first?.values.first { $0.type == .string }?.data
    }

    /// Fresh objects every call: writing an item that is already associated with a pasteboard raises.
    func makeItems() -> [NSPasteboardItem]? {
        makePasteboardItems(firstString: nil)
    }

    func makeItems(replacingFirstStringWith text: String) -> [NSPasteboardItem]? {
        guard firstStringData != nil else { return nil }
        return makePasteboardItems(firstString: text)
    }

    private func makePasteboardItems(firstString: String?) -> [NSPasteboardItem]? {
        guard let items else { return nil }
        var pasteboardItems: [NSPasteboardItem] = []
        pasteboardItems.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            let pasteboardItem = NSPasteboardItem()
            var replacedString = false
            // Declaration order is significant — a receiver takes the first type it understands — so
            // the substitution happens in place rather than by writing the string first.
            for value in item.values {
                if index == 0, let firstString, value.type == .string, !replacedString {
                    guard pasteboardItem.setString(firstString, forType: .string) else { return nil }
                    replacedString = true
                    continue
                }
                guard pasteboardItem.setData(value.data, forType: value.type) else { return nil }
            }
            pasteboardItems.append(pasteboardItem)
        }
        return pasteboardItems
    }
}

/// Borrows the general pasteboard for one paste and gives it back.
///
/// The point is `inPlace`: the original item object is mutated back, so returning the user's
/// clipboard does not bump `changeCount` and clipboard managers never record a second entry.
@MainActor
final class TemporaryPasteboardLease {
    enum RestoreResult: Equatable {
        case restored(changeCount: Int)
        /// Someone copied over us; their content wins.
        case superseded
        /// Still ours, but the write failed — worth retrying.
        case failed
    }

    private enum Strategy {
        /// The first item carried plain text: only its string payload was swapped, so handing the
        /// clipboard back costs no change count at all.
        case inPlace(temporaryItem: NSPasteboardItem, originalStringData: Data)
        /// The first item carried no plain text (image, file) or the pasteboard was empty: the
        /// snapshot is rewritten wholesale, which bumps `changeCount` once, as the old code did.
        case rewrite(PasteboardSnapshot)
    }

    private let pasteboard: any SnippetPasteboardAccess
    private let ownedChangeCount: Int
    private let strategy: Strategy
    private var isFinished = false

    var isOwned: Bool { !isFinished && pasteboard.changeCount == ownedChangeCount }

    private init(
        pasteboard: any SnippetPasteboardAccess,
        ownedChangeCount: Int,
        strategy: Strategy
    ) {
        self.pasteboard = pasteboard
        self.ownedChangeCount = ownedChangeCount
        self.strategy = strategy
    }

    /// `nil` means the pasteboard could not be read back safely. The caller must then abandon the
    /// expansion — which is why the lease is taken before the trigger is deleted, not after.
    static func begin(
        text: String,
        pasteboard: any SnippetPasteboardAccess
    ) -> TemporaryPasteboardLease? {
        let snapshot = PasteboardSnapshot(reading: pasteboard)
        guard let items = snapshot.items, pasteboard.changeCount == snapshot.changeCount else {
            return nil
        }

        if let originalStringData = snapshot.firstStringData,
           let temporaryItems = snapshot.makeItems(replacingFirstStringWith: text),
           let temporaryItem = temporaryItems.first {
            pasteboard.clearContents()
            guard pasteboard.writeObjects(temporaryItems) else {
                if let originalItems = snapshot.makeItems() {
                    _ = pasteboard.writeObjects(originalItems)
                }
                return nil
            }
            return TemporaryPasteboardLease(
                pasteboard: pasteboard,
                ownedChangeCount: pasteboard.changeCount,
                strategy: .inPlace(temporaryItem: temporaryItem, originalStringData: originalStringData)
            )
        }

        let temporaryItem = NSPasteboardItem()
        guard temporaryItem.setString(text, forType: .string) else { return nil }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([temporaryItem]) else {
            if !items.isEmpty, let originalItems = snapshot.makeItems() {
                _ = pasteboard.writeObjects(originalItems)
            }
            return nil
        }
        return TemporaryPasteboardLease(
            pasteboard: pasteboard,
            ownedChangeCount: pasteboard.changeCount,
            strategy: .rewrite(snapshot)
        )
    }

    /// Idempotent: after a successful restore, later calls report `.superseded`.
    func restoreIfOwned() -> RestoreResult {
        guard !isFinished else { return .superseded }
        guard pasteboard.changeCount == ownedChangeCount else {
            isFinished = true
            return .superseded
        }

        switch strategy {
        case .inPlace(let temporaryItem, let originalStringData):
            guard temporaryItem.setData(originalStringData, forType: .string) else {
                if pasteboard.changeCount != ownedChangeCount {
                    isFinished = true
                    return .superseded
                }
                return .failed
            }
            guard pasteboard.changeCount == ownedChangeCount else {
                isFinished = true
                return .superseded
            }
            isFinished = true
            return .restored(changeCount: ownedChangeCount)

        case .rewrite(let snapshot):
            guard let items = snapshot.makeItems() else { return .failed }
            pasteboard.clearContents()
            guard items.isEmpty || pasteboard.writeObjects(items) else {
                isFinished = true
                return .failed
            }
            isFinished = true
            return .restored(changeCount: pasteboard.changeCount)
        }
    }
}
