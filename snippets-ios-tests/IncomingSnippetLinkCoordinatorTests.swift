import XCTest
@testable import Snippets

@MainActor
final class IncomingSnippetLinkCoordinatorTests: XCTestCase {
    private var supportDirectory: URL!

    override func setUpWithError() throws {
        supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IncomingSnippetLinkCoordinatorTests-\(UUID())", isDirectory: true)
        setenv(SnippetStorageLocations.rootOverrideEnvironmentKey, supportDirectory.path, 1)
        SnippetStorageLocations.createAllDirectories()
    }

    override func tearDownWithError() throws {
        unsetenv(SnippetStorageLocations.rootOverrideEnvironmentKey)
        if let supportDirectory {
            try? FileManager.default.removeItem(at: supportDirectory)
        }
        supportDirectory = nil
    }

    func testShareLinkDoesNotMutateBeforeAcceptanceAndReplacementIsDisabled() throws {
        let store = SnippetStore(configuration: .iOS)
        var trusted = store.addSnippet(name: "Trusted", content: "trusted body")
        trusted.keyword = "sig"
        store.update(trusted)
        store.flushPendingWrites()

        let incoming = Snippet(name: "Incoming", keyword: "sig", content: "external body")
        let url = try SnippetDeepLink.url(for: incoming, isSecure: false)
        let coordinator = IncomingSnippetLinkCoordinator(store: store)

        let review = try coordinator.makeReview(for: url)
        XCTAssertEqual(store.snippet(id: trusted.id)?.content, "trusted body")
        XCTAssertEqual(review.replacedSnippet?.id, trusted.id)

        let action = try coordinator.apply(review)
        XCTAssertEqual(action.snippetID, trusted.id)
        XCTAssertEqual(store.snippet(id: trusted.id)?.content, "external body")
        XCTAssertEqual(store.snippet(id: trusted.id)?.isEnabled, false)
    }

    func testShareReviewRejectsRecordThatAppearsAfterNonreplacementReview() throws {
        let store = SnippetStore(configuration: .iOS)
        let incoming = Snippet(name: "Incoming", keyword: "sig", content: "external body")
        let url = try SnippetDeepLink.url(for: incoming, isSecure: false)
        let coordinator = IncomingSnippetLinkCoordinator(store: store)

        let review = try coordinator.makeReview(for: url)
        XCTAssertNil(review.replacedSnippet)

        var appeared = store.addSnippet(name: "Appeared", content: "keep this body")
        appeared.keyword = "sig"
        store.update(appeared)
        store.flushPendingWrites()
        let libraryBeforeApply = store.snippets
        let fileBeforeApply = try Data(contentsOf: SnippetStorageLocations.snippetsFileURL)

        XCTAssertThrowsError(try coordinator.apply(review)) { error in
            XCTAssertEqual(error as? IncomingSnippetLinkCoordinator.ReviewError, .libraryChanged)
            XCTAssertEqual(
                error.localizedDescription,
                "Your library changed while this link was open. Review the link again before importing it."
            )
        }
        XCTAssertEqual(store.snippets, libraryBeforeApply)
        XCTAssertEqual(
            try Data(contentsOf: SnippetStorageLocations.snippetsFileURL),
            fileBeforeApply
        )
        XCTAssertEqual(store.snippet(id: appeared.id)?.content, "keep this body")
    }

    func testShareReviewRejectsChangedReplacementWithoutAnyMutation() throws {
        let store = SnippetStore(configuration: .iOS)
        var trusted = store.addSnippet(name: "Trusted", content: "original body")
        trusted.keyword = "sig"
        store.update(trusted)
        store.flushPendingWrites()

        let incoming = Snippet(name: "Incoming", keyword: "sig", content: "external body")
        let url = try SnippetDeepLink.url(for: incoming, isSecure: false)
        let coordinator = IncomingSnippetLinkCoordinator(store: store)
        let review = try coordinator.makeReview(for: url)
        XCTAssertEqual(review.replacedSnippet?.id, trusted.id)

        var edited = try XCTUnwrap(store.snippet(id: trusted.id))
        edited.content = "edited while alert was open"
        store.update(edited)
        store.flushPendingWrites()
        let libraryBeforeApply = store.snippets
        let fileBeforeApply = try Data(contentsOf: SnippetStorageLocations.snippetsFileURL)

        XCTAssertThrowsError(try coordinator.apply(review)) { error in
            XCTAssertEqual(error as? IncomingSnippetLinkCoordinator.ReviewError, .libraryChanged)
        }
        XCTAssertEqual(store.snippets, libraryBeforeApply)
        XCTAssertEqual(
            try Data(contentsOf: SnippetStorageLocations.snippetsFileURL),
            fileBeforeApply
        )
        XCTAssertEqual(store.snippet(id: trusted.id)?.content, "edited while alert was open")
    }

    func testUnchangedShareReviewStillSucceeds() throws {
        let store = SnippetStore(configuration: .iOS)
        var trusted = store.addSnippet(name: "Trusted", content: "trusted body")
        trusted.keyword = "sig"
        store.update(trusted)
        store.flushPendingWrites()

        let incoming = Snippet(name: "Incoming", keyword: "sig", content: "external body")
        let url = try SnippetDeepLink.url(for: incoming, isSecure: false)
        let coordinator = IncomingSnippetLinkCoordinator(store: store)
        let review = try coordinator.makeReview(for: url)

        let action = try coordinator.apply(review)

        XCTAssertEqual(action, .imported(trusted.id))
        XCTAssertEqual(store.snippet(id: trusted.id)?.content, "external body")
        XCTAssertFalse(try XCTUnwrap(store.snippet(id: trusted.id)?.isEnabled))
    }

    func testCreationLinkCreatesAUniqueDisabledSnippet() throws {
        let store = SnippetStore(configuration: .iOS)
        var existing = store.addSnippet(name: "Existing", content: "keep")
        existing.keyword = "sig"
        store.update(existing)
        store.flushPendingWrites()

        let url = try XCTUnwrap(URL(string: "snippets://new?name=New&keyword=sig&content=linked"))
        let coordinator = IncomingSnippetLinkCoordinator(store: store)
        let review = try coordinator.makeReview(for: url)
        let action = try coordinator.apply(review)

        XCTAssertNotEqual(action.snippetID, existing.id)
        XCTAssertEqual(store.snippets.count, 2)
        let created = try XCTUnwrap(store.snippet(id: action.snippetID))
        XCTAssertEqual(created.normalizedKeyword, "sig")
        XCTAssertEqual(created.content, "linked")
        XCTAssertFalse(created.isEnabled)
        XCTAssertEqual(store.snippet(id: existing.id)?.content, "keep")
    }
}
