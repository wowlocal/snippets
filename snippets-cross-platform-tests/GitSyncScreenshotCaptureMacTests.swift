#if os(macOS)
import AppKit
import XCTest
@testable import Snippets_Debug

/// Temporary: renders the Git sheet's states for a UX review. Runs only when
/// /tmp/snippets-git-shots-enable exists.
@MainActor
final class GitSyncScreenshotCaptureMacTests: XCTestCase {
    func testCaptureSheetStates() throws {
        guard FileManager.default.fileExists(atPath: "/tmp/snippets-git-shots-enable") else { throw XCTSkip("capture only") }
        let output = URL(fileURLWithPath: try String(contentsOfFile: "/tmp/snippets-git-shots-enable", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let suite = "GitShots-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let selection = SyncBackendSelectionStore(
            defaults: try XCTUnwrap(UserDefaults(suiteName: suite)),
            keychain: KeychainSecretStore(tier: .deviceOnly, inMemory: true),
            bootstrapSecrets: KeychainSecretStore(tier: .deviceOnly, inMemory: true),
            snippetsCloudEnabled: false,
            gitKeys: GitSyncKeyStore(keychain: KeychainSecretStore(tier: .deviceOnly, inMemory: true)),
            gitCredentials: KeychainSecretStore(tier: .deviceOnly, inMemory: true))

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearance == .aqua ? "light" : "dark"
            let sheet = MacGitSyncViewController(selection: selection, coordinator: nil) {}
            try render(sheet, appearance: appearance, to: output.appendingPathComponent("mac-01-empty-\(suffix).png"))
            sheet.urlField.stringValue = "https://github.com/you/snippets-library"
            sheet.updateAccessMethod()
            try render(sheet, appearance: appearance, to: output.appendingPathComponent("mac-02-https-github-\(suffix).png"))
            sheet.urlField.stringValue = "git@github.com:you/snippets-library.git"
            sheet.updateAccessMethod()
            try render(sheet, appearance: appearance, to: output.appendingPathComponent("mac-03-ssh-\(suffix).png"))
        }

        let coordinates = SyncBackendSelectionStore.GitCoordinates(
            repository: try GitRepositoryLocation.parse("https://github.com/you/snippets-library"),
            branch: "main", username: "you", datasetID: UUID(), mode: .plainText)
        try selection.configureGit(coordinates, token: "github_pat_example")
        try selection.gitKeys.install(GitSyncKeyStore.mintMaterial(), for: coordinates.keyScope)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearance == .aqua ? "light" : "dark"
            let connected = MacGitSyncViewController(selection: selection, coordinator: nil) {}
            try render(connected, appearance: appearance,
                       to: output.appendingPathComponent("mac-04-connected-plain-\(suffix).png"))
        }
    }

    /// Renders the sheet as it appears: on the window background, at the height its
    /// content asks for, in the given appearance.
    private func render(_ controller: MacGitSyncViewController, appearance: NSAppearance.Name, to url: URL) throws {
        let view = controller.view
        controller.reloadState()
        let backdrop = Backdrop(frame: .zero)
        backdrop.appearance = NSAppearance(named: appearance)
        view.removeFromSuperview()
        backdrop.addSubview(view)
        view.layoutSubtreeIfNeeded()
        let size = NSSize(width: MacGitSyncViewController.sheetWidth, height: view.fittingSize.height)
        backdrop.frame = NSRect(origin: .zero, size: size)
        view.frame = backdrop.bounds
        backdrop.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds))
        backdrop.cacheDisplay(in: backdrop.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    /// `cacheDisplay` does not draw a window's background, so draw it here.
    private final class Backdrop: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor.windowBackgroundColor.setFill()
            dirtyRect.fill()
        }
    }
}
#endif
