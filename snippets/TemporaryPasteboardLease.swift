import AppKit

/// The slice of `NSPasteboard` the lease uses. It exists so a test harness can stand in a fake.
@MainActor
protocol SnippetPasteboardAccess: AnyObject {
    var changeCount: Int { get }
    var pasteboardItems: [NSPasteboardItem]? { get }
    @discardableResult func clearContents() -> Int
    /// `NSPasteboard` already has this; the protocol carries it so the concealed path
    /// can scope a write to this Mac and the test fake can observe that it did.
    @discardableResult func prepareForNewContents(with options: NSPasteboard.ContentsOptions) -> Int
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
        // AppKit uses `nil` to report that the pasteboard could not be read. It is not the
        // same state as an empty array: treating a failed read as an empty clipboard would
        // let `begin` clear content that we have no way to restore.
        guard let pasteboardItems = pasteboard.pasteboardItems else {
            self.items = nil
            self.changeCount = changeCount
            return
        }
        var captured: [Item] = []
        for pasteboardItem in pasteboardItems {
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
    enum AcquisitionResult {
        case acquired(TemporaryPasteboardLease)
        /// Nothing destructive happened, rollback completed, or a newer user copy won.
        case refused
        /// The temporary write failed and the pasteboard still belongs to us, but bounded
        /// rollback could not yet return the captured snapshot. The caller must retain this
        /// lease and retry restoration; it must not delete or paste any text.
        case recoveryPending(TemporaryPasteboardLease)

        var acquiredLease: TemporaryPasteboardLease? {
            guard case .acquired(let lease) = self else { return nil }
            return lease
        }

        var isRefused: Bool {
            if case .refused = self { return true }
            return false
        }
    }

    enum RestoreResult: Equatable {
        case restored(changeCount: Int)
        /// Someone copied over us; their content wins.
        case superseded
        /// Still ours, but the write failed — worth retrying. The lease deliberately stays
        /// unfinished so `isOwned` keeps reporting `true`: that is the only thing separating
        /// "we could not hand the clipboard back" from "someone else took it", and the caller
        /// must not mistake the first for a clean handback.
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
    /// The change count our own last write left behind. `var`, because the rewrite restore
    /// clears the pasteboard before it writes and that moves the count: re-anchoring keeps the
    /// question `isOwned` asks — "has anyone copied since we last wrote?" — answerable.
    private var ownedChangeCount: Int
    private let strategy: Strategy
    private var isFinished = false

    /// Also the failure signal: a restore that could not put the user's data back leaves the
    /// lease unfinished, so `isOwned` stays `true` to say we still owe the clipboard back.
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

    /// Markers that ask clipboard managers not to record an item.
    ///
    /// There is no AppKit constant for these — they are a community convention that the
    /// major clipboard managers happen to honour, so this is **a courtesy, not a
    /// control**. Anything that ignores them still sees the text, and the threat model
    /// says so. The reason to set them anyway is that a secret silently accumulating in
    /// someone's clipboard history is the most likely real-world leak this feature has,
    /// and the mitigation costs two lines.
    ///
    /// The genuine protection is elsewhere: secure expansion prefers the Accessibility
    /// write path, which never touches the pasteboard at all.
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// `.refused` means no usable temporary lease was acquired and no restoration debt remains.
    /// `.recoveryPending` means acquisition failed after clearing and the caller must retain the
    /// returned lease until the original snapshot is restored or a newer user copy supersedes it.
    /// This is why acquisition happens before the trigger is deleted, not after.
    ///
    /// - Parameter isConcealed: set for secure-snippet content. Adds the
    ///   clipboard-manager opt-out markers described on `concealedType`.
    static func begin(
        text: String,
        pasteboard: any SnippetPasteboardAccess,
        isConcealed: Bool = false
    ) -> AcquisitionResult {
        let snapshot = PasteboardSnapshot(reading: pasteboard)
        guard !snapshot.isUnavailable, pasteboard.changeCount == snapshot.changeCount else {
            return .refused
        }

        // The in-place strategy can restore the original string bytes without a
        // second pasteboard write, but NSPasteboardItem has no API for removing the
        // concealed/transient marker types afterwards. Secure content therefore uses
        // the snapshot/rewrite strategy below so its markers disappear with it.
        if !isConcealed,
           let originalStringData = snapshot.firstStringData,
           let temporaryItems = snapshot.makeItems(replacingFirstStringWith: text),
           let temporaryItem = temporaryItems.first {
            // Building the replacement can take arbitrary local work. Recheck immediately before
            // the destructive operation so a copy made while we were building always wins.
            guard pasteboard.changeCount == snapshot.changeCount else { return .refused }
            let acquiredChangeCount = pasteboard.clearContents()
            guard pasteboard.writeObjects(temporaryItems) else {
                // A writer can take the pasteboard while our write is failing. Never recover over
                // that newer content; otherwise retry a few times with fresh item objects.
                let rolledBack = restoreSnapshot(
                    snapshot,
                    to: pasteboard,
                    whileOwnedAt: acquiredChangeCount
                )
                return failedAcquisitionResult(
                    snapshot: snapshot,
                    pasteboard: pasteboard,
                    ownedChangeCount: acquiredChangeCount,
                    rolledBack: rolledBack
                )
            }
            // If ownership changed during the write, the later owner wins and there is no lease.
            guard pasteboard.changeCount == acquiredChangeCount else { return .refused }
            return .acquired(
                TemporaryPasteboardLease(
                    pasteboard: pasteboard,
                    ownedChangeCount: acquiredChangeCount,
                    strategy: .inPlace(
                        temporaryItem: temporaryItem,
                        originalStringData: originalStringData
                    )
                )
            )
        }

        let temporaryItem = NSPasteboardItem()
        guard temporaryItem.setString(text, forType: .string) else { return .refused }
        if isConcealed {
            // Local item mutation belongs before the last ownership check. However unlikely, a
            // copy made while adding marker flavors must win instead of being cleared below.
            Self.markConcealed(temporaryItem)
        }
        // As above, do not clear a clipboard that changed while the temporary item was built.
        guard pasteboard.changeCount == snapshot.changeCount else { return .refused }
        let acquiredChangeCount: Int
        if isConcealed {
            // Scope the write to this Mac. Without it, Universal Clipboard can carry a
            // secret to the user's iPhone and iPad, where `ConcealedType` means nothing
            // at all — the marker is a macOS clipboard-manager convention, not a
            // cross-device one. This is the one place the courtesy becomes a control.
            acquiredChangeCount = pasteboard.prepareForNewContents(with: .currentHostOnly)
        } else {
            acquiredChangeCount = pasteboard.clearContents()
        }
        guard pasteboard.writeObjects([temporaryItem]) else {
            let rolledBack = restoreSnapshot(
                snapshot,
                to: pasteboard,
                whileOwnedAt: acquiredChangeCount
            )
            return failedAcquisitionResult(
                snapshot: snapshot,
                pasteboard: pasteboard,
                ownedChangeCount: acquiredChangeCount,
                rolledBack: rolledBack
            )
        }
        guard pasteboard.changeCount == acquiredChangeCount else { return .refused }
        return .acquired(
            TemporaryPasteboardLease(
                pasteboard: pasteboard,
                ownedChangeCount: acquiredChangeCount,
                strategy: .rewrite(snapshot)
            )
        )
    }

    private static func failedAcquisitionResult(
        snapshot: PasteboardSnapshot,
        pasteboard: any SnippetPasteboardAccess,
        ownedChangeCount: Int,
        rolledBack: Bool
    ) -> AcquisitionResult {
        guard !rolledBack,
              snapshot.items?.isEmpty == false,
              pasteboard.changeCount == ownedChangeCount
        else {
            return .refused
        }
        return .recoveryPending(
            TemporaryPasteboardLease(
                pasteboard: pasteboard,
                ownedChangeCount: ownedChangeCount,
                strategy: .rewrite(snapshot)
            )
        )
    }

    /// Best-effort rollback for a temporary write that never acquired a lease. Each attempt uses
    /// fresh `NSPasteboardItem` instances, because AppKit refuses objects already associated with
    /// a pasteboard. The ownership check is repeated immediately before every write; a newer copy
    /// is always more important than our stale snapshot.
    private static func restoreSnapshot(
        _ snapshot: PasteboardSnapshot,
        to pasteboard: any SnippetPasteboardAccess,
        whileOwnedAt ownedChangeCount: Int,
        maxAttempts: Int = 3
    ) -> Bool {
        guard let snapshotItems = snapshot.items else { return false }
        if snapshotItems.isEmpty {
            return pasteboard.changeCount == ownedChangeCount
        }

        for _ in 0..<max(0, maxAttempts) {
            // Reconstruct first, then perform the ownership check at the last possible point.
            guard let originalItems = snapshot.makeItems(),
                  pasteboard.changeCount == ownedChangeCount
            else { return false }
            if pasteboard.writeObjects(originalItems) {
                return pasteboard.changeCount == ownedChangeCount
            }
        }
        return false
    }

    /// Both markers, because managers differ on which they read. Failures are ignored:
    /// a manager that refuses the type is exactly the manager that was never going to
    /// honour it, and losing the whole expansion over a hint would be the wrong trade.
    private static func markConcealed(_ item: NSPasteboardItem) {
        _ = item.setString("", forType: concealedType)
        _ = item.setString("", forType: transientType)
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
            guard pasteboard.changeCount == ownedChangeCount else {
                isFinished = true
                return .superseded
            }
            // `clearContents` moves the change count, so the count `begin` handed us can never
            // match again. Re-anchor on our own write before anything can fail: a newer copy by
            // the user still pushes the count past this one, so the "never overwrite a newer
            // copy" guard keeps its meaning, while a failed write no longer masquerades as
            // `superseded` on the next attempt.
            ownedChangeCount = pasteboard.clearContents()
            if items.isEmpty || pasteboard.writeObjects(items) {
                guard pasteboard.changeCount == ownedChangeCount else {
                    isFinished = true
                    return .superseded
                }
                isFinished = true
                return .restored(changeCount: pasteboard.changeCount)
            }
            // The clipboard is empty right now and that is our doing. Rebuild the items and try
            // once more, the same recovery the acquisition path performs — a write can fail for
            // reasons that do not survive building fresh `NSPasteboardItem`s.
            // Recheck after the failed write as well: another app may have copied while that
            // synchronous request was in flight, and its newer content must not be overwritten.
            guard pasteboard.changeCount == ownedChangeCount else {
                isFinished = true
                return .superseded
            }
            if let rebuilt = snapshot.makeItems(),
               pasteboard.changeCount == ownedChangeCount,
               pasteboard.writeObjects(rebuilt) {
                guard pasteboard.changeCount == ownedChangeCount else {
                    isFinished = true
                    return .superseded
                }
                isFinished = true
                return .restored(changeCount: pasteboard.changeCount)
            }
            guard pasteboard.changeCount == ownedChangeCount else {
                isFinished = true
                return .superseded
            }
            // Left cleared. `isFinished` stays false on purpose: `isOwned` remains true, the
            // caller's retry loop gets its remaining attempts, and a caller that runs out of
            // them reports failure instead of calling an emptied clipboard a success.
            return .failed
        }
    }

    /// Production retry policy for handing the user's clipboard back. Returning `true` means
    /// either the snapshot was restored or a newer owner superseded us; `false` means the lease
    /// still owns the pasteboard and therefore still owes the snapshot back.
    func restoreWithRetries(maxAttempts: Int = 3) -> Bool {
        for _ in 0..<max(0, maxAttempts) {
            guard isOwned else { break }
            if case .failed = restoreIfOwned() { continue }
            break
        }
        return !isOwned
    }
}
