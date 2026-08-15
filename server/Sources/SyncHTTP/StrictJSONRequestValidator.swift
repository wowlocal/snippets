import Foundation
import SyncDomain

enum StrictJSONRequestValidator {
    static func validate(_ data: Data, operationID: String) throws {
        do {
            var scanner = JSONScanner(bytes: data)
            try scanner.validate()

            // JSONDecoder cannot distinguish a missing nullable property from
            // an explicitly supplied null. These two properties are required
            // by the public contract because omission changes CAS semantics.
            switch operationID {
            case "createSpace":
                guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      root["idempotencyKey"].map({ $0 is String }) ?? true
                else { throw SyncServiceError.invalidRequest }
            case "submitRecords":
                guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let items = root["items"] as? [[String: Any]],
                      items.allSatisfy({ item in
                          guard let value = item["expectedRecordVersion"] else { return false }
                          return value is String || value is NSNull
                      })
                else { throw SyncServiceError.invalidRequest }
            case "putRecoveryKeyEnvelope":
                guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let value = root["expectedVersion"],
                      value is NSNumber || value is NSNull
                else { throw SyncServiceError.invalidRequest }
            default:
                break
            }
        } catch let error as SyncServiceError {
            throw error
        } catch {
            throw SyncServiceError.invalidRequest
        }
    }
}

private struct JSONScanner {
    private let bytes: Data
    private var index = 0
    private let maximumDepth = 32

    init(bytes: Data) {
        self.bytes = bytes
    }

    mutating func validate() throws {
        skipWhitespace()
        try parseValue(depth: 0)
        skipWhitespace()
        guard index == bytes.count else { throw SyncServiceError.invalidRequest }
    }

    private mutating func parseValue(depth: Int) throws {
        guard depth <= maximumDepth, index < bytes.count else { throw SyncServiceError.invalidRequest }
        switch bytes[index] {
        case 0x7b: try parseObject(depth: depth)
        case 0x5b: try parseArray(depth: depth)
        case 0x22: _ = try parseString()
        case 0x74: try consumeLiteral([0x74, 0x72, 0x75, 0x65])
        case 0x66: try consumeLiteral([0x66, 0x61, 0x6c, 0x73, 0x65])
        case 0x6e: try consumeLiteral([0x6e, 0x75, 0x6c, 0x6c])
        case 0x2d, 0x30...0x39: try parseNumber()
        default: throw SyncServiceError.invalidRequest
        }
    }

    private mutating func parseObject(depth: Int) throws {
        try consume(0x7b)
        skipWhitespace()
        if consumeIfPresent(0x7d) { return }
        var keys = Set<String>()
        while true {
            let keyData = try parseString()
            guard keyData.count <= 1_024,
                  let key = try? JSONDecoder().decode(String.self, from: keyData),
                  keys.insert(key).inserted
            else { throw SyncServiceError.invalidRequest }
            skipWhitespace()
            try consume(0x3a)
            skipWhitespace()
            try parseValue(depth: depth + 1)
            skipWhitespace()
            if consumeIfPresent(0x7d) { return }
            try consume(0x2c)
            skipWhitespace()
        }
    }

    private mutating func parseArray(depth: Int) throws {
        try consume(0x5b)
        skipWhitespace()
        if consumeIfPresent(0x5d) { return }
        while true {
            try parseValue(depth: depth + 1)
            skipWhitespace()
            if consumeIfPresent(0x5d) { return }
            try consume(0x2c)
            skipWhitespace()
        }
    }

    private mutating func parseString() throws -> Data {
        let start = index
        try consume(0x22)
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == 0x22 {
                return Data(bytes[start..<index])
            }
            guard byte >= 0x20 else { throw SyncServiceError.invalidRequest }
            if byte == 0x5c {
                guard index < bytes.count else { throw SyncServiceError.invalidRequest }
                let escape = bytes[index]
                index += 1
                switch escape {
                case 0x22, 0x2f, 0x5c, 0x62, 0x66, 0x6e, 0x72, 0x74:
                    break
                case 0x75:
                    guard index <= bytes.count - 4,
                          bytes[index..<(index + 4)].allSatisfy(Self.isHexDigit)
                    else { throw SyncServiceError.invalidRequest }
                    index += 4
                default:
                    throw SyncServiceError.invalidRequest
                }
            }
        }
        throw SyncServiceError.invalidRequest
    }

    private mutating func parseNumber() throws {
        _ = consumeIfPresent(0x2d)
        guard index < bytes.count else { throw SyncServiceError.invalidRequest }
        if consumeIfPresent(0x30) {
            if index < bytes.count, Self.isDigit(bytes[index]) {
                throw SyncServiceError.invalidRequest
            }
        } else {
            guard consumeDigit(range: 0x31...0x39) else { throw SyncServiceError.invalidRequest }
            while consumeDigit(range: 0x30...0x39) {}
        }
        if consumeIfPresent(0x2e) {
            guard consumeDigit(range: 0x30...0x39) else { throw SyncServiceError.invalidRequest }
            while consumeDigit(range: 0x30...0x39) {}
        }
        if consumeIfPresent(0x65) || consumeIfPresent(0x45) {
            _ = consumeIfPresent(0x2b) || consumeIfPresent(0x2d)
            guard consumeDigit(range: 0x30...0x39) else { throw SyncServiceError.invalidRequest }
            while consumeDigit(range: 0x30...0x39) {}
        }
    }

    private mutating func consumeLiteral(_ literal: [UInt8]) throws {
        guard index <= bytes.count - literal.count,
              bytes[index..<(index + literal.count)].elementsEqual(literal)
        else { throw SyncServiceError.invalidRequest }
        index += literal.count
    }

    private mutating func consume(_ expected: UInt8) throws {
        guard consumeIfPresent(expected) else { throw SyncServiceError.invalidRequest }
    }

    private mutating func consumeIfPresent(_ expected: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == expected else { return false }
        index += 1
        return true
    }

    private mutating func consumeDigit(range: ClosedRange<UInt8>) -> Bool {
        guard index < bytes.count, range.contains(bytes[index]) else { return false }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0a, 0x0d].contains(bytes[index]) {
            index += 1
        }
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte)
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
    }
}
