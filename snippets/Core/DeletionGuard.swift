import Foundation

// Compiled into the app, the CLI, and the test package — see `Snippet.swift`.

/// The circuit breaker between a broken backend and the user's library.
///
/// ## What this is defending against
///
/// Everything else in the sync layer assumes the remote is *wrong sometimes*. This
/// assumes it is occasionally **catastrophically** wrong, in the one direction that
/// cannot be undone:
///
/// - An S3 bucket restored from a snapshot taken before half the library existed. Every
///   missing record now looks like a deletion, and the delta says so.
/// - A CloudKit zone that returns an empty page because the container was reset.
/// - A truncated manifest: the fetch succeeded, the body was cut off, and the records
///   that were not in it look deleted.
/// - Our own bug. A cursor handled wrongly, an off-by-one in a page loop.
///
/// In every one of those, the correct sync behaviour and the disastrous one are the
/// same code path. The merge cannot tell them apart, because the remote is telling it
/// the truth about what the remote contains.
///
/// ## Why a threshold rather than a smarter test
///
/// There is no test that distinguishes "the user tidied up" from "the backend lost
/// half the bucket", because at the byte level those are identical. What differs is
/// scale, and scale is something a user can confirm in one dialog. So the guard is
/// deliberately crude: refuse anything large, let the user look, and make the refusal
/// *sticky* — `SyncState.HaltReason.massDeletion` never auto-heals, because
/// auto-healing a mass deletion means performing it.
///
/// The floor of five is what makes this usable. A pure percentage would refuse to
/// delete one record from a library of four, which is both wrong and infuriating; and
/// a small library is exactly where a percentage is meaningless.
nonisolated enum DeletionGuard {

    /// How many deletions may be applied against a library of `liveCount` records.
    ///
    /// `max(5, ceil(0.2 * liveCount))`, computed in integer arithmetic: `(2n + 9) / 10`
    /// is exactly `ceil(n / 5)` for every non-negative `Int`, by construction.
    ///
    /// The floating-point spelling, `Int(ceil(0.2 * Double(liveCount)))`, was checked
    /// and does in fact agree for every library size anyone will ever have — `0.2` is
    /// not representable in binary, but the error stays well under half an ulp at these
    /// magnitudes. It is not used anyway. A safety limit is the one function whose
    /// boundary behaviour has to be *provable* rather than *verified up to 100 000*,
    /// because the boundary is the only part of it anybody will ever read.
    static func allowedDeletions(liveCount: Int) -> Int {
        max(Self.floor, (max(0, liveCount) * 2 + 9) / 10)
    }

    /// Below this many records, the percentage is noise and the floor governs.
    static let floor = 5

    /// Why a batch was refused. Carries the numbers rather than a formatted string, so
    /// the UI, the CLI, and `SyncState.Halt.detail` can each say it their own way.
    struct Refusal: Equatable, Sendable, CustomStringConvertible {
        var liveCount: Int
        var requestedDeletions: Int
        var allowedDeletions: Int

        /// The share of the library the remote asked to remove, for a UI that would
        /// rather say "83% of your snippets" than "40 of 48".
        var requestedFraction: Double {
            liveCount > 0 ? Double(requestedDeletions) / Double(liveCount) : 1
        }

        var description: String {
            "the sync backend asked to delete \(requestedDeletions) of \(liveCount) "
                + "snippet\(liveCount == 1 ? "" : "s"); at most \(allowedDeletions) "
                + "may be applied without confirmation"
        }
    }

    enum Decision: Equatable, Sendable {
        case allow
        case refuse(Refusal)

        var isAllowed: Bool { if case .allow = self { return true } else { return false } }

        var refusal: Refusal? { if case .refuse(let refusal) = self { return refusal } else { return nil } }
    }

    /// The whole guard, as a pure function of two counts.
    ///
    /// - Parameters:
    ///   - liveCount: how many records the library holds **before** the batch is
    ///     applied. Live records only — a tombstone is not something that can be
    ///     deleted again.
    ///   - deletions: how many of those the incoming batch would remove.
    static func evaluate(liveCount: Int, deletions: Int) -> Decision {
        let allowed = allowedDeletions(liveCount: liveCount)
        // Zero deletions is always fine, including against an empty library, so a first
        // sync against a fresh backend is never refused for having nothing to say.
        guard deletions > allowed else { return .allow }
        return .refuse(Refusal(
            liveCount: liveCount, requestedDeletions: deletions, allowedDeletions: allowed))
    }

    /// The same decision from the sets the caller actually has, which removes the two
    /// ways to get the counts wrong: counting a deletion of something we do not hold,
    /// and counting the same id twice because it arrived twice.
    ///
    /// An at-least-once transport *will* deliver duplicates — `InMemoryTransport` has a
    /// fault mode for it — and a duplicate-inflated count would trip the breaker on a
    /// batch that deletes nothing new.
    static func evaluate(live: Set<UUID>, deleting: some Sequence<UUID>) -> Decision {
        let effective = Set(deleting).intersection(live)
        return evaluate(liveCount: live.count, deletions: effective.count)
    }

    /// Convenience over a batch of opened envelopes.
    static func evaluate(live: Set<UUID>, incoming: [SyncEnvelope]) -> Decision {
        evaluate(live: live, deleting: incoming.lazy.filter(\.deleted).map(\.id))
    }
}
