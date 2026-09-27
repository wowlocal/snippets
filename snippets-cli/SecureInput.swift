import Foundation
import Darwin

/// Secret sources are explicit and mutually exclusive. This type never prints input,
/// expands shell text, reads environment variables, or writes temporary files.
enum SecureInput {
    case standardInput
    case file(String)
    case descriptor(Int32)
    case prompt

    enum Failure: Error, CustomStringConvertible {
        case unavailable, unsafeFile, terminal, tooLarge, invalidText
        var description: String {
            switch self {
            case .unavailable: "could not read secure input"
            case .unsafeFile: "secure files must be regular, owned by you, and inaccessible to group/others; symlinks are not accepted"
            case .terminal: "use --prompt for hidden terminal input, or pipe/redirect secure input"
            case .tooLarge: "secure content exceeds the input limit"
            case .invalidText: "secure content must be non-empty UTF-8"
            }
        }
    }

    func read(maximumBytes: Int) throws -> Data {
        let data: Data
        switch self {
        case .prompt:
            // libc restores termios on handled signals (including Ctrl-C), requires
            // /dev/tty, and never falls back to echoing stdin. Read one extra byte so
            // an overlong line cannot silently become a different, truncated secret.
            var buffer = [CChar](repeating: -91, count: maximumBytes + 2)
            defer { buffer.withUnsafeMutableBytes { _ = memset_s($0.baseAddress!, $0.count, 0, $0.count) } }
            let result = buffer.withUnsafeMutableBufferPointer {
                readpassphrase("Secure content (one line): ", $0.baseAddress!, $0.count,
                               RPP_ECHO_OFF | RPP_REQUIRE_TTY)
            }
            guard result != nil, let end = buffer.lastIndex(where: { $0 != -91 }) else {
                throw Failure.unavailable
            }
            // The terminating NUL differs from the sentinel even when the user types
            // NUL bytes. Preserve every entered byte before it; never use strlen.
            guard end <= maximumBytes else { throw Failure.tooLarge }
            data = buffer.withUnsafeBytes { Data($0.prefix(end)) }
        case .file(let path):
            let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { throw Failure.unsafeFile }
            defer { close(fd) }
            try Self.validate(fd, requireRegular: true)
            data = try Self.readBytes(fd, maximumBytes: maximumBytes)
        case .standardInput, .descriptor:
            let source: Int32
            if case .descriptor(let fd) = self { source = fd } else { source = STDIN_FILENO }
            guard source >= 0 else { throw Failure.unavailable }
            let fd = fcntl(source, F_DUPFD_CLOEXEC, 3)
            guard fd >= 0 else { throw Failure.unavailable }
            defer { close(fd) }
            try Self.validate(fd, requireRegular: false)
            data = try Self.readBytes(fd, maximumBytes: maximumBytes)
        }
        guard !data.isEmpty, String(data: data, encoding: .utf8) != nil else { throw Failure.invalidText }
        return data
    }

    private static func validate(_ fd: Int32, requireRegular: Bool) throws {
        guard isatty(fd) == 0 else { throw Failure.terminal }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw Failure.unavailable }
        let kind = info.st_mode & S_IFMT
        if kind == S_IFREG {
            guard info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw Failure.unsafeFile }
        } else if requireRegular || kind != S_IFIFO {
            throw Failure.unsafeFile
        }
    }

    private static func readBytes(_ fd: Int32, maximumBytes: Int) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        defer { buffer.withUnsafeMutableBytes { _ = memset_s($0.baseAddress!, $0.count, 0, $0.count) } }
        while true {
            let count = Darwin.read(fd, &buffer, min(buffer.count, maximumBytes + 1 - data.count))
            if count < 0 {
                if errno == EINTR { continue }
                throw Failure.unavailable
            }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= maximumBytes else { throw Failure.tooLarge }
        }
    }
}
