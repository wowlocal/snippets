import XCTest
@testable import SnippetsCore

final class SettingsCatalogTests: XCTestCase {
    func testMacNavigationMatchesProductInformationArchitecture() {
        XCTAssertEqual(
            SettingsCatalog.navigationSections(for: .macOS).flatMap(\.destinations),
            [.general, .expansion, .clipboardHistory, .sync, .secureSnippets, .backup, .integrations, .diagnostics, .about]
        )
    }

    func testIOSNavigationContainsOnlyMobileDestinations() {
        XCTAssertEqual(
            SettingsCatalog.navigationSections(for: .iOS).flatMap(\.destinations),
            [.sync, .secureSnippets, .backup, .diagnostics, .about]
        )
    }

    func testSearchRoutesIndividualRowsToTheirDestination() {
        let results = SettingsCatalog.search("encrypted backup", platform: .macOS)
        XCTAssertEqual(results.first?.rowID, .encryptedBackup)
        XCTAssertEqual(results.first?.destination, .backup)
    }

    func testSearchSupportsKeywordsAndMultipleTokens() {
        let result = SettingsCatalog.search("browser bundle", platform: .macOS).first
        XCTAssertEqual(result?.rowID, .chromiumApps)
        XCTAssertEqual(result?.destination, .integrations)
    }

    func testIOSSearchDoesNotExposeMacOnlyRows() {
        XCTAssertTrue(SettingsCatalog.search("launch startup", platform: .iOS).isEmpty)
        XCTAssertTrue(SettingsCatalog.search("command line", platform: .iOS).isEmpty)
        XCTAssertTrue(SettingsCatalog.search("clipboard", platform: .iOS).isEmpty)
    }

    func testClipboardHistorySearchFindsCapturePrivacyAndClearControlsOnMac() {
        XCTAssertEqual(
            SettingsCatalog.search("command shift v", platform: .macOS).first?.rowID,
            .clipboardHistoryEnabled)
        XCTAssertEqual(
            SettingsCatalog.search("clear clipboard", platform: .macOS).first?.rowID,
            .clearClipboardHistory)
        XCTAssertEqual(
            SettingsCatalog.search("clipboard exclude", platform: .macOS).first?.rowID,
            .clipboardExcludedApps)
        XCTAssertTrue(SettingsCatalog.search("clipboard", platform: .macOS)
            .allSatisfy { $0.destination == .clipboardHistory })
    }

    func testCatalogContainsOnlyStaticProductCopy() {
        let indexedText = SettingsCatalog.entries(for: .macOS)
            .flatMap { [$0.title, $0.detail ?? ""] }
            .joined(separator: " ")
            .lowercased()

        XCTAssertFalse(indexedText.contains("snippet body"))
        XCTAssertFalse(indexedText.contains("ciphertext"))
        XCTAssertFalse(indexedText.contains("record uuid"))
    }
}
