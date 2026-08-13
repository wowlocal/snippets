import Foundation
import XCTest
@testable import SyncDomain

final class OpaqueTokenCodecTests: XCTestCase {
    func testRoundTripAndTamperResistance() throws {
        let codec = try OpaqueTokenCodec(secret: Data(repeating: 0x42, count: 32))
        let payload = CursorPayload(
            kind: .delta,
            serverInstanceID: UUID(),
            spaceID: UUID(),
            datasetGeneration: UUID(),
            feedEpoch: UUID(),
            sequence: 12
        )
        let encoded = try codec.encode(payload)
        XCTAssertEqual(try codec.decode(CursorPayload.self, token: encoded), payload)
        XCTAssertThrowsError(try codec.decode(CursorPayload.self, token: encoded + "A"))
    }

    func testDifferentSecretCannotVerify() throws {
        let first = try OpaqueTokenCodec(secret: Data(repeating: 1, count: 32))
        let second = try OpaqueTokenCodec(secret: Data(repeating: 2, count: 32))
        let payload = CursorPayload(
            kind: .snapshot,
            serverInstanceID: UUID(),
            spaceID: UUID(),
            datasetGeneration: UUID(),
            feedEpoch: UUID(),
            sequence: 0,
            snapshotHighWater: 100
        )
        XCTAssertThrowsError(try second.decode(CursorPayload.self, token: first.encode(payload)))
    }
}
