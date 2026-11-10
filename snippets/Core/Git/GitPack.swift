import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import zlib

// Compiled into the apps and the test package. Not part of `snippets-cli`.

/// zlib, as git uses it: one complete zlib stream per object.
nonisolated enum GitZlib {
    static func deflate(_ input: Data) throws -> Data {
        var capacity = compressBound(uLong(input.count))
        var output = Data(count: Int(capacity))
        let status = output.withUnsafeMutableBytes { outputBuffer in
            input.withUnsafeBytes { inputBuffer in
                compress2(
                    outputBuffer.bindMemory(to: Bytef.self).baseAddress,
                    &capacity,
                    inputBuffer.bindMemory(to: Bytef.self).baseAddress,
                    uLong(input.count),
                    Z_DEFAULT_COMPRESSION)
            }
        }
        guard status == Z_OK else { throw GitFormatError.compression }
        output.count = Int(capacity)
        return output
    }

    /// Inflates the single zlib stream that begins at `offset` and must expand to
    /// exactly `expectedSize` bytes. Returns the bytes and how much input it consumed:
    /// a pack does not record compressed lengths, so this is the only way to find the
    /// next entry. zlib stops at the stream's end and reports `total_in` exactly.
    static func inflate(
        _ input: UnsafeBufferPointer<UInt8>, from offset: Int, expectedSize: Int
    ) throws -> (content: [UInt8], consumed: Int) {
        guard let base = input.baseAddress, offset < input.count else {
            throw GitFormatError.compression
        }
        var stream = z_stream()
        guard inflateInit_(&stream, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw GitFormatError.compression
        }
        defer { inflateEnd(&stream) }
        // One spare byte turns a stream that is longer than declared into a detectable
        // error rather than a silently truncated object.
        var output = [UInt8](repeating: 0, count: expectedSize + 1)
        let available = min(input.count - offset, Int(UInt32.max))
        let status: Int32 = output.withUnsafeMutableBufferPointer { outputBuffer in
            stream.next_in = UnsafeMutablePointer(mutating: base + offset)
            stream.avail_in = uInt(available)
            stream.next_out = outputBuffer.baseAddress
            stream.avail_out = uInt(outputBuffer.count)
            var status: Int32
            repeat {
                status = zlib.inflate(&stream, Z_NO_FLUSH)
            } while status == Z_OK && stream.avail_in > 0 && stream.avail_out > 0
            return status
        }
        guard status == Z_STREAM_END, Int(stream.total_out) == expectedSize else {
            throw GitFormatError.compression
        }
        output.removeLast()
        return (output, Int(stream.total_in))
    }
}

/// Git's binary delta format (`gitformat-pack(5)`, "Deltified representation").
nonisolated enum GitDelta {
    static func apply(_ delta: [UInt8], to base: [UInt8], maximumSize: Int) throws -> [UInt8] {
        var index = 0
        func size() throws -> Int {
            var value = 0
            var shift = 0
            while true {
                guard index < delta.count, shift < 63 else { throw GitFormatError.invalidDelta }
                let byte = delta[index]
                index += 1
                value |= Int(byte & 0x7f) << shift
                shift += 7
                if byte & 0x80 == 0 { return value }
            }
        }
        guard try size() == base.count else { throw GitFormatError.invalidDelta }
        let targetSize = try size()
        guard targetSize <= maximumSize else { throw GitFormatError.limitExceeded("delta_target") }
        var output = [UInt8]()
        output.reserveCapacity(targetSize)
        while index < delta.count {
            let opcode = delta[index]
            index += 1
            if opcode & 0x80 != 0 {
                var copyOffset = 0
                var copySize = 0
                for bit in 0..<4 where opcode & (1 << bit) != 0 {
                    guard index < delta.count else { throw GitFormatError.invalidDelta }
                    copyOffset |= Int(delta[index]) << (8 * bit)
                    index += 1
                }
                for bit in 0..<3 where opcode & (0x10 << bit) != 0 {
                    guard index < delta.count else { throw GitFormatError.invalidDelta }
                    copySize |= Int(delta[index]) << (8 * bit)
                    index += 1
                }
                if copySize == 0 { copySize = 0x10000 }
                guard copyOffset + copySize <= base.count,
                      output.count + copySize <= targetSize else { throw GitFormatError.invalidDelta }
                output.append(contentsOf: base[copyOffset..<(copyOffset + copySize)])
            } else if opcode != 0 {
                let length = Int(opcode)
                guard index + length <= delta.count,
                      output.count + length <= targetSize else { throw GitFormatError.invalidDelta }
                output.append(contentsOf: delta[index..<(index + length)])
                index += length
            } else {
                throw GitFormatError.invalidDelta
            }
        }
        guard output.count == targetSize else { throw GitFormatError.invalidDelta }
        return output
    }
}

/// Reads and writes version-2 packfiles.
nonisolated enum GitPack {
    struct Limits: Sendable {
        var maximumObjects = 2_000_000
        var maximumObjectBytes = 64 * 1024 * 1024
        #if os(iOS)
        var maximumTotalInflatedBytes = 384 * 1024 * 1024
        #else
        var maximumTotalInflatedBytes = 1024 * 1024 * 1024
        #endif
        var maximumDeltaDepth = 10_000
    }

    private enum Entry {
        case whole(GitObjectType, [UInt8])
        case offsetDelta(baseOffset: Int, delta: [UInt8])
        case referenceDelta(base: GitObjectID, delta: [UInt8])
    }

    /// Decodes every object, resolving both delta forms. `externalBase` supplies
    /// objects a thin pack references but omits; this client never asks for thin packs,
    /// so production callers pass the local cache only as a defensive fallback.
    static func parse(
        _ pack: Data,
        limits: Limits = Limits(),
        externalBase: (GitObjectID) -> GitObject? = { _ in nil }
    ) throws -> [GitObjectID: GitObject] {
        let bytes = [UInt8](pack)
        guard bytes.count >= 12 + GitObjectID.byteCount,
              bytes[0..<4].elementsEqual(Array("PACK".utf8)) else {
            throw GitFormatError.invalidPack("signature")
        }
        let version = bigEndian32(bytes, at: 4)
        guard version == 2 || version == 3 else { throw GitFormatError.invalidPack("version") }
        let count = Int(bigEndian32(bytes, at: 8))
        guard count <= limits.maximumObjects else { throw GitFormatError.limitExceeded("pack_objects") }

        let trailerStart = bytes.count - GitObjectID.byteCount
        let checksum = Array(Insecure.SHA1.hash(data: bytes[0..<trailerStart]))
        guard checksum.elementsEqual(bytes[trailerStart...]) else {
            throw GitFormatError.invalidPack("checksum")
        }

        var entries: [Int: Entry] = [:]
        var order: [Int] = []
        // The header's count is untrusted until each entry has actually been read.
        entries.reserveCapacity(min(count, 65_536))
        order.reserveCapacity(min(count, 65_536))
        var inflatedTotal = 0
        var offset = 12
        try bytes.withUnsafeBufferPointer { buffer in
            for _ in 0..<count {
                let entryOffset = offset
                guard offset < trailerStart else { throw GitFormatError.invalidPack("truncated") }
                var byte = bytes[offset]
                offset += 1
                let typeCode = (byte >> 4) & 0x07
                var size = Int(byte & 0x0f)
                var shift = 4
                while byte & 0x80 != 0 {
                    guard offset < trailerStart, shift < 57 else { throw GitFormatError.invalidPack("header") }
                    byte = bytes[offset]
                    offset += 1
                    size |= Int(byte & 0x7f) << shift
                    shift += 7
                }
                guard size <= limits.maximumObjectBytes else {
                    throw GitFormatError.limitExceeded("pack_object")
                }
                let entry: Entry
                switch typeCode {
                case 1, 2, 3, 4:
                    let (content, consumed) = try GitZlib.inflate(buffer, from: offset, expectedSize: size)
                    offset += consumed
                    entry = .whole(GitObjectType(rawValue: typeCode)!, content)
                case 6:
                    guard offset < trailerStart else { throw GitFormatError.invalidPack("truncated") }
                    byte = bytes[offset]
                    offset += 1
                    var distance = Int(byte & 0x7f)
                    while byte & 0x80 != 0 {
                        guard offset < trailerStart, distance < Int.max >> 8 else {
                            throw GitFormatError.invalidPack("offset")
                        }
                        byte = bytes[offset]
                        offset += 1
                        distance = ((distance + 1) << 7) | Int(byte & 0x7f)
                    }
                    let baseOffset = entryOffset - distance
                    guard distance > 0, baseOffset >= 12 else { throw GitFormatError.invalidPack("offset") }
                    let (delta, consumed) = try GitZlib.inflate(buffer, from: offset, expectedSize: size)
                    offset += consumed
                    entry = .offsetDelta(baseOffset: baseOffset, delta: delta)
                case 7:
                    guard offset + GitObjectID.byteCount <= trailerStart,
                          let base = GitObjectID(bytes: bytes[offset..<(offset + GitObjectID.byteCount)])
                    else { throw GitFormatError.invalidPack("reference") }
                    offset += GitObjectID.byteCount
                    let (delta, consumed) = try GitZlib.inflate(buffer, from: offset, expectedSize: size)
                    offset += consumed
                    entry = .referenceDelta(base: base, delta: delta)
                default:
                    throw GitFormatError.invalidPack("type")
                }
                guard offset <= trailerStart else { throw GitFormatError.invalidPack("truncated") }
                inflatedTotal += size
                guard inflatedTotal <= limits.maximumTotalInflatedBytes else {
                    throw GitFormatError.limitExceeded("pack_inflated")
                }
                entries[entryOffset] = entry
                order.append(entryOffset)
            }
        }
        guard offset == trailerStart else { throw GitFormatError.invalidPack("trailing_data") }

        // Resolve breadth-first from every undeltified object, so each delta is applied
        // exactly once no matter how long its chain is. Offset deltas name a position;
        // reference deltas name an object id that may itself be produced by a delta.
        var objects: [GitObjectID: GitObject] = [:]
        var childrenByOffset: [Int: [Int]] = [:]
        var childrenByID: [GitObjectID: [Int]] = [:]
        var queue: [(offset: Int, object: GitObject, depth: Int)] = []
        var resolvedCount = 0
        for entryOffset in order {
            switch entries[entryOffset]! {
            case .whole(let type, let content):
                queue.append((entryOffset, GitObject(type: type, content: Data(content)), 0))
            case .offsetDelta(let baseOffset, _):
                guard entries[baseOffset] != nil else { throw GitFormatError.invalidPack("offset_base") }
                childrenByOffset[baseOffset, default: []].append(entryOffset)
            case .referenceDelta(let baseID, _):
                childrenByID[baseID, default: []].append(entryOffset)
            }
        }

        func deltaPayload(_ entryOffset: Int) -> [UInt8] {
            switch entries[entryOffset]! {
            case .offsetDelta(_, let delta), .referenceDelta(_, let delta): delta
            case .whole: []
            }
        }

        var head = 0
        while true {
            while head < queue.count {
                let (entryOffset, object, depth) = queue[head]
                head += 1
                resolvedCount += 1
                let id = object.id
                objects[id] = object
                let children = (childrenByOffset.removeValue(forKey: entryOffset) ?? [])
                    + (childrenByID.removeValue(forKey: id) ?? [])
                guard !children.isEmpty else { continue }
                guard depth < limits.maximumDeltaDepth else {
                    throw GitFormatError.limitExceeded("delta_depth")
                }
                let base = [UInt8](object.content)
                for child in children {
                    let content = try GitDelta.apply(
                        deltaPayload(child), to: base, maximumSize: limits.maximumObjectBytes)
                    inflatedTotal += content.count
                    guard inflatedTotal <= limits.maximumTotalInflatedBytes else {
                        throw GitFormatError.limitExceeded("pack_inflated")
                    }
                    queue.append((child, GitObject(type: object.type, content: Data(content)), depth + 1))
                }
            }
            // Anything left refers to an object outside this pack.
            guard let (baseID, children) = childrenByID.first,
                  let base = externalBase(baseID) else { break }
            childrenByID[baseID] = nil
            let baseBytes = [UInt8](base.content)
            for child in children {
                let content = try GitDelta.apply(
                    deltaPayload(child), to: baseBytes, maximumSize: limits.maximumObjectBytes)
                inflatedTotal += content.count
                guard inflatedTotal <= limits.maximumTotalInflatedBytes else {
                    throw GitFormatError.limitExceeded("pack_inflated")
                }
                queue.append((child, GitObject(type: base.type, content: Data(content)), 1))
            }
        }
        guard resolvedCount == count else { throw GitFormatError.invalidPack("unresolved_delta") }
        return objects
    }

    /// An undeltified pack. Records are already ciphertext, so deltas would not
    /// compress them anyway, and an undeltified pack can never depend on a base the
    /// server lacks.
    static func build(_ objects: [GitObject]) throws -> Data {
        var data = Data("PACK".utf8)
        appendBigEndian32(2, to: &data)
        appendBigEndian32(UInt32(objects.count), to: &data)
        for object in objects {
            var size = object.content.count
            var byte = UInt8(object.type.rawValue << 4) | UInt8(size & 0x0f)
            size >>= 4
            while size > 0 {
                data.append(byte | 0x80)
                byte = UInt8(size & 0x7f)
                size >>= 7
            }
            data.append(byte)
            data.append(try GitZlib.deflate(object.content))
        }
        data.append(contentsOf: Insecure.SHA1.hash(data: data))
        return data
    }

    private static func bigEndian32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    private static func appendBigEndian32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value >> 24))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }
}
