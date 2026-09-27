import Foundation
import Darwin
import Testing
@testable import SnippetsCore

@Suite("Secure CLI input")
struct SecureAddIPCTests {
    @Test func roundTripAndBounds() throws {
        var input = SnippetsIPC.SecureAdd(name: "Demo", keyword: "demo",
            body: Data("synthetic\nсекрет\n".utf8), tags: [], isEnabled: true, isPinned: false)
        let request = SnippetsIPC.Request(command: SnippetsIPC.Command.addSecure, secureAdd: input)
        let decoded = try JSONDecoder().decode(SnippetsIPC.Request.self, from: JSONEncoder().encode(request))
        #expect(decoded.secureAdd?.body == input.body)
        #expect(decoded.invocation == nil)
        #expect(input.isValid)
        input.body = Data([0xff])
        #expect(!input.isValid)
        input.body = Data()
        #expect(!input.isValid)
        input.body = Data(repeating: 65, count: SnippetsIPC.SecureAdd.maximumBodyBytes)
        #expect(input.isValid)
        input.body.append(65)
        #expect(!input.isValid)
        input.body = Data([65])
        input.keyword = " "
        #expect(!input.isValid)
    }

    @Test func newlineTerminatedMessageStillHonorsLimit() throws {
        var descriptors: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        defer { close(descriptors[0]); close(descriptors[1]) }
        try UnixSocket.send(String(repeating: "a", count: 30), on: descriptors[0])
        #expect(throws: UnixSocket.Failure.self) {
            try UnixSocket.receive(String.self, on: descriptors[1], limit: 10)
        }
    }

    @Test func creationReceiptHasNoBody() throws {
        let response = SnippetsIPC.Response(status: .ok, createdID: UUID())
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any])
        #expect(Set(object.keys) == ["v", "status", "createdID"])
    }
}
