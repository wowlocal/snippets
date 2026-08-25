import Darwin
import UIKit
import XCTest
@testable import Snippets

@MainActor
final class SnippetEditorScrollTests: XCTestCase {
    private var rootURL: URL!
    private var previousSyncPreference: Any?

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnippetEditorScrollTests-\(UUID().uuidString)", isDirectory: true)
        setenv(SnippetStorageLocations.rootOverrideEnvironmentKey, rootURL.path, 1)
        previousSyncPreference = UserDefaults.standard.object(
            forKey: SyncCoordinator.enabledDefaultsKey
        )
        UserDefaults.standard.set(false, forKey: SyncCoordinator.enabledDefaultsKey)
    }

    override func tearDownWithError() throws {
        unsetenv(SnippetStorageLocations.rootOverrideEnvironmentKey)
        if let previousSyncPreference {
            UserDefaults.standard.set(previousSyncPreference, forKey: SyncCoordinator.enabledDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: SyncCoordinator.enabledDefaultsKey)
        }
        previousSyncPreference = nil
        if let rootURL { try? FileManager.default.removeItem(at: rootURL) }
        rootURL = nil
    }

    func testOuterEditorScrollsOnlyWhenTheFormExceedsTheVisibleHeight() throws {
        let environment = AppEnvironment()
        let snippet = try! environment.store.addSnippet(name: "Geometry", content: "Short")
        var updated = try XCTUnwrap(environment.store.snippet(id: snippet.id))
        updated.keyword = "geometry"
        environment.store.update(updated)

        let hosted = try hostEditor(environment: environment, snippetID: snippet.id)
        defer {
            hosted.window.endEditing(true)
            hosted.window.isHidden = true
            hosted.window.rootViewController = nil
            hosted.previousKeyWindow?.makeKey()
        }

        XCTAssertTrue(hosted.scrollView.bounces)
        XCTAssertFalse(hosted.scrollView.alwaysBounceVertical)
        XCTAssertLessThanOrEqual(verticalScrollRange(of: hosted.scrollView), 0.5)

        let formStack = try XCTUnwrap(
            hosted.scrollView.subviews.compactMap { $0 as? UIStackView }.first
        )
        XCTAssertEqual(
            hosted.scrollView.contentSize.height,
            formStack.frame.maxY,
            accuracy: 0.5,
            "Decorative bottom spacing must not create an empty scroll range"
        )

        updated.content = Array(repeating: "{clipboard}", count: 8).joined(separator: "\n")
        environment.store.update(updated)
        hosted.editor.bind(to: snippet.id)
        hosted.editor.view.layoutIfNeeded()

        XCTAssertGreaterThan(verticalScrollRange(of: hosted.scrollView), 0.5)
    }

    func testKeyboardInsetRequiresTheKeyboardToIntersectTheEditor() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)

        XCTAssertEqual(
            KeyboardInsetGeometry.bottomOverlap(
                of: CGRect(x: 0, y: 440, width: 800, height: 160),
                in: bounds),
            160)
        XCTAssertEqual(
            KeyboardInsetGeometry.bottomOverlap(
                of: CGRect(x: 900, y: 440, width: 800, height: 160),
                in: bounds),
            0,
            "A keyboard on another display or beside this window must not create a scroll inset"
        )
        XCTAssertEqual(
            KeyboardInsetGeometry.bottomOverlap(
                of: CGRect(x: 0, y: 700, width: 800, height: 160),
                in: bounds),
            0)
    }

    private func hostEditor(
        environment: AppEnvironment,
        snippetID: UUID
    ) throws -> (
        window: UIWindow,
        previousKeyWindow: UIWindow?,
        editor: SnippetEditorViewController,
        scrollView: UIScrollView
    ) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let windowScene = try XCTUnwrap(scene)
        let previousKeyWindow = windowScene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: windowScene)
        window.frame = CGRect(x: 0, y: 0, width: 1180, height: 820)

        let root = MainSplitViewController(environment: environment)
        window.rootViewController = root
        window.makeKeyAndVisible()
        root.loadViewIfNeeded()
        root.view.layoutIfNeeded()

        let listNavigation = try XCTUnwrap(
            root.viewController(for: .primary) as? UINavigationController
        )
        let editorNavigation = try XCTUnwrap(
            root.viewController(for: .secondary) as? UINavigationController
        )
        let list = try XCTUnwrap(listNavigation.topViewController as? SnippetListViewController)
        let editor = try XCTUnwrap(
            editorNavigation.topViewController as? SnippetEditorViewController
        )
        root.snippetList(list, selected: snippetID)
        root.view.layoutIfNeeded()
        editor.view.layoutIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))

        let scrollView = try XCTUnwrap(
            editor.view.subviews.compactMap { $0 as? UIScrollView }.first
        )
        return (window, previousKeyWindow, editor, scrollView)
    }

    private func verticalScrollRange(of scrollView: UIScrollView) -> CGFloat {
        scrollView.contentSize.height
            + scrollView.adjustedContentInset.top
            + scrollView.adjustedContentInset.bottom
            - scrollView.bounds.height
    }
}
