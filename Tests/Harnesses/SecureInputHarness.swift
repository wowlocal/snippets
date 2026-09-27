import Foundation
import CryptoKit

@main
struct SecureInputHarness {
    static func main() {
        let args = CommandLine.arguments
        let source: SecureInput
        switch args[1] {
        case "file": source = .file(args[2])
        case "fd": source = .descriptor(Int32(args[2])!)
        case "prompt": source = .prompt
        default: source = .standardInput
        }
        do {
            let body = try source.read(maximumBytes: 64)
            print("OK " + SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined())
        } catch let error as SecureInput.Failure {
            fputs(error.description + "\n", stderr)
            exit(1)
        } catch { exit(2) }
    }
}
