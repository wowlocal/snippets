import Foundation

/// Stores the active sync provider without coupling either transport to Settings UI.
///
/// Non-secret coordinates live in UserDefaults. The bearer token is device-only
/// Keychain data: it is not synchronized through iCloud Keychain and is never written
/// to diagnostics. Changing this selection does not delete either provider's data.
@MainActor
final class SyncBackendSelectionStore {
    enum Provider: String, CaseIterable {
        case iCloud = "icloud"
        case snippetsCloud = "snippets-cloud"

        var displayName: String {
            switch self {
            case .iCloud: "iCloud"
            case .snippetsCloud: "Snippets Cloud"
            }
        }
    }

    struct CloudCoordinates: Equatable {
        var serverURL: URL
        var spaceID: UUID
    }

    enum Failure: Error, CustomStringConvertible {
        case missingConfiguration
        case missingCredential
        case invalidCredential

        var description: String {
            switch self {
            case .missingConfiguration: "Snippets Cloud is not configured"
            case .missingCredential: "Snippets Cloud needs sign-in"
            case .invalidCredential: "the stored Snippets Cloud credential is invalid"
            }
        }
    }

    static let providerDefaultsKey = "SnippetsSyncProvider"
    static let pendingSwitchDefaultsKey = "SnippetsSyncProviderSwitchPending"
    private static let serverDefaultsKey = "SnippetsCloudServerURL"
    private static let spaceDefaultsKey = "SnippetsCloudSpaceID"
    private static let tokenAccount = "oidc-access-token-v1"

    private let defaults: UserDefaults
    private let keychain: KeychainSecretStore

    init(
        defaults: UserDefaults = .standard,
        keychain: KeychainSecretStore? = nil
    ) {
        self.defaults = defaults
        self.keychain = keychain ?? KeychainSecretStore(
            tier: .deviceOnly,
            service: "com.khm.snippets.sync-http")
    }

    var provider: Provider {
        get { Provider(rawValue: defaults.string(forKey: Self.providerDefaultsKey) ?? "") ?? .iCloud }
        set { defaults.set(newValue.rawValue, forKey: Self.providerDefaultsKey) }
    }

    var cloudCoordinates: CloudCoordinates? {
        guard let rawURL = defaults.string(forKey: Self.serverDefaultsKey),
              let url = URL(string: rawURL),
              let rawSpace = defaults.string(forKey: Self.spaceDefaultsKey),
              let spaceID = UUID(uuidString: rawSpace) else { return nil }
        return CloudCoordinates(serverURL: url, spaceID: spaceID)
    }

    var hasPendingProviderSwitch: Bool {
        defaults.bool(forKey: Self.pendingSwitchDefaultsKey)
    }

    func selectICloud() {
        markSwitch(to: .iCloud)
    }

    func selectSnippetsCloud(
        serverURL: URL,
        spaceID: UUID,
        accessToken: String
    ) throws {
        let configuration = try SnippetsCloudTransport.Configuration(
            baseURL: serverURL,
            spaceID: spaceID,
            accessToken: accessToken)
        try keychain.storeItem(Data(configuration.accessToken.utf8), account: Self.tokenAccount)
        defaults.set(configuration.baseURL.absoluteString, forKey: Self.serverDefaultsKey)
        defaults.set(configuration.spaceID.uuidString.lowercased(), forKey: Self.spaceDefaultsKey)
        markSwitch(to: .snippetsCloud)
    }

    func makeTransport() throws -> any SyncTransport {
        switch provider {
        case .iCloud:
            return CloudKitTransport()
        case .snippetsCloud:
            guard let coordinates = cloudCoordinates else { throw Failure.missingConfiguration }
            guard let tokenData = try keychain.loadItem(account: Self.tokenAccount) else {
                throw Failure.missingCredential
            }
            guard let token = String(data: tokenData, encoding: .utf8) else {
                throw Failure.invalidCredential
            }
            return SnippetsCloudTransport(configuration: try .init(
                baseURL: coordinates.serverURL,
                spaceID: coordinates.spaceID,
                accessToken: token))
        }
    }

    func clearPendingProviderSwitch() {
        defaults.set(false, forKey: Self.pendingSwitchDefaultsKey)
    }

    private func markSwitch(to selected: Provider) {
        // Setting the same provider after changing its endpoint/token can still be an
        // account-scope transition and needs the exact same journal-first handoff.
        provider = selected
        defaults.set(true, forKey: Self.pendingSwitchDefaultsKey)
    }
}
