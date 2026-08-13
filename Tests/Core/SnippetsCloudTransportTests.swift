import Foundation
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

    private static func scope(space: UUID, dataset: UUID, feed: UUID) -> [String: Any] {
        [
            "spaceId": space.uuidString.lowercased(),
            "scopeBinding": String(repeating: "b", count: 32),
            "datasetGeneration": dataset.uuidString.lowercased(),
            "feedEpoch": feed.uuidString.lowercased(),
        ]
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
