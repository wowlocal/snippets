import Foundation
import CryptoKit
import Testing
@testable import SnippetsCore

@Suite(.serialized)
struct SnippetsCloudTransportTests {
    @Test func configurationRequiresHTTPSAndBoundedCredentials() throws {
        #expect(throws: SnippetsCloudTransport.ConfigurationFailure.invalidServerURL) {
            _ = try SnippetsCloudTransport.Configuration(
                baseURL: #require(URL(string: "http://sync.example.test")),
                spaceID: UUID(),
                accessToken: "valid-token")
        }
        #expect(throws: SnippetsCloudTransport.ConfigurationFailure.invalidAccessToken) {
            _ = try SnippetsCloudTransport.Configuration(
                baseURL: #require(URL(string: "https://sync.example.test")),
                spaceID: UUID(),
                accessToken: "short")
        }
    }

    @Test func fetchMapsOpaqueRecordAndBindsEveryResponseToScope() async throws {
        let space = UUID()
        let dataset = UUID()
        let feed = UUID()
        let recordID = UUID()
        let recordVersion = String(repeating: "a", count: 32)
        let configuration = try SnippetsCloudTransport.Configuration(
            baseURL: #require(URL(string: "https://sync.example.test")),
            spaceID: space,
            accessToken: "test-access-token")

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [CloudURLProtocol.self]
        CloudURLProtocol.handler = { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-access-token")
            let path = try #require(request.url?.path)
            let object: [String: Any]
            if path.hasSuffix("/scope") {
                object = Self.scope(space: space, dataset: dataset, feed: feed)
            } else {
                object = Self.scope(space: space, dataset: dataset, feed: feed).merging([
                    "records": [[
                        "id": recordID.uuidString.lowercased(),
                        "rev": "opaque-rev",
                        "deleted": false,
                        "blob": Data("ciphertext".utf8).base64EncodedString(),
                        "recordVersion": recordVersion,
                    ]],
                    "cursor": "cursor-1",
                    "hasMore": false,
                    "fullSnapshot": true,
                ], uniquingKeysWith: { _, new in new })
            }
            return (200, try JSONSerialization.data(withJSONObject: object))
        }

        let transport = SnippetsCloudTransport(
            configuration: configuration,
            session: URLSession(configuration: sessionConfiguration))
        #expect(transport.supportsPush)
        let identity = try #require(try await transport.resolveAccountIdentity())
        let fetch = try await transport.fetchChanges(since: nil)
        #expect(fetch.accountIdentity == identity)
        #expect(fetch.cursor == SyncCursor("cursor-1"))
        #expect(fetch.isFullResync)
        #expect(fetch.records.count == 1)
        #expect(fetch.records[0].id == recordID)
        #expect(fetch.records[0].blob == Data("ciphertext".utf8))
        #expect(String(data: try #require(fetch.records[0].recordVersion).data, encoding: .utf8)
                == recordVersion)
    }

    @Test func createEncodesRequiredExpectedVersionAsExplicitNull() async throws {
        let space = UUID()
        let dataset = UUID()
        let feed = UUID()
        let recordID = UUID()
        let recordVersion = String(repeating: "v", count: 32)
        let configuration = try SnippetsCloudTransport.Configuration(
            baseURL: #require(URL(string: "https://sync.example.test")),
            spaceID: space,
            accessToken: "test-access-token")
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [CloudURLProtocol.self]
        CloudURLProtocol.handler = { request in
            let path = try #require(request.url?.path)
            if path.hasSuffix("/scope") {
                return (200, try JSONSerialization.data(withJSONObject:
                    Self.scope(space: space, dataset: dataset, feed: feed)))
            }
            let body = try Self.bodyData(request)
            let root = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let items = try #require(root["items"] as? [[String: Any]])
            let item = try #require(items.first)
            #expect(item.keys.contains("expectedRecordVersion"))
            #expect(item["expectedRecordVersion"] is NSNull)
            let response = Self.scope(space: space, dataset: dataset, feed: feed).merging([
                "outcomes": [[
                    "kind": "accepted",
                    "revision": "opaque-rev",
                    "recordVersion": recordVersion,
                ]],
                "partial": false,
            ], uniquingKeysWith: { _, new in new })
            return (200, try JSONSerialization.data(withJSONObject: response))
        }

        let transport = SnippetsCloudTransport(
            configuration: configuration,
            session: URLSession(configuration: sessionConfiguration))
        let submission = try await transport.submit([
            WireRecord(
                id: recordID,
                rev: "opaque-rev",
                deleted: false,
                blob: Data("ciphertext".utf8))
        ], at: nil)

        #expect(submission.acceptedIDs == [recordID])
    }

    @Test func liveHTTPSServiceCarriesAppleCiphertextThatAndroidCanOpen() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SNIPPETS_CLOUD_E2E"] == "1" else { return }
        let server = try #require(environment["SNIPPETS_CLOUD_E2E_SERVER_URL"])
        let token = try #require(environment["SNIPPETS_CLOUD_E2E_ACCESS_TOKEN"])
        let space = try #require(environment["SNIPPETS_CLOUD_E2E_SPACE_ID"])
        let configuration = try SnippetsCloudTransport.Configuration(
            baseURL: try #require(URL(string: server)),
            spaceID: try #require(UUID(uuidString: space)),
            accessToken: token)
        let transport = SnippetsCloudTransport(configuration: configuration)
        let initial = try await transport.fetchChanges(since: nil)
        #expect(initial.records.isEmpty, "the live E2E test requires a disposable empty space")

        let createdAt = Date(timeIntervalSince1970: 1_786_579_200)
        let snippet = Snippet(
            id: Self.appleRecordID,
            name: "Apple Core E2E",
            keyword: "apple-e2e",
            content: Self.applePlaintextProbe,
            tags: ["integration", "apple"],
            isEnabled: true,
            isPinned: true,
            createdAt: createdAt,
            updatedAt: createdAt)
        let sealer = SnippetCryptoSealer(
            keyring: SnippetCrypto.Keyring(
                libraryKey: SymmetricKey(data: Data(repeating: 0x42, count: 32)),
                salt: Data(repeating: 0x24, count: 32)),
            scopeID: "sync-v1")
        let record = try WireCodec.seal(
            .plain(
                snippet,
                hlc: HLC(wallMs: 1_786_579_200_000, counter: 0, device: "a11ce001"),
                origin: "a11ce001"),
            using: sealer)

        let submission = try await transport.submit([record], at: initial.cursor)
        #expect(submission.acceptedIDs == [Self.appleRecordID])
        let fetched = try await transport.fetchChanges(since: nil)
        let stored = try #require(fetched.records.first { $0.id == Self.appleRecordID })
        let opened = try WireCodec.open(stored, using: sealer)
        #expect(opened.plainSnippet == snippet)
        #expect(!stored.blob.containsSubsequence(Data(Self.applePlaintextProbe.utf8)))
    }

    private static func scope(space: UUID, dataset: UUID, feed: UUID) -> [String: Any] {
        [
            "spaceId": space.uuidString.lowercased(),
            "scopeBinding": String(repeating: "b", count: 32),
            "datasetGeneration": dataset.uuidString.lowercased(),
            "feedEpoch": feed.uuidString.lowercased(),
        ]
    }

    private static func bodyData(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try #require(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw try #require(stream.streamError) }
            if count == 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }

    private static let appleRecordID = UUID(
        uuidString: "a11ce001-0000-4000-8000-000000000001")!
    private static let applePlaintextProbe = "snippets-apple-e2e-plaintext-probe-8d134f53"
}

private extension Data {
    func containsSubsequence(_ needle: Data) -> Bool {
        guard !needle.isEmpty else { return true }
        return indices.contains { start in
            start + needle.count <= endIndex
                && self[start..<(start + needle.count)].elementsEqual(needle)
        }
    }
}

private final class CloudURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try #require(Self.handler)
            let (status, data) = try handler(request)
            let requestURL = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: requestURL,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
