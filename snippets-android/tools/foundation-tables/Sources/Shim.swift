import Foundation

// `SnippetLibraryCodec.read(from:)` uses this helper, which the app declares in
// `snippets/Core/LibraryGeneration.swift` beside code this tool does not need.
extension NSError {
    var isFileNotFound: Bool {
        (domain == NSCocoaErrorDomain
            && (code == NSFileReadNoSuchFileError || code == NSFileNoSuchFileError))
            || (domain == NSPOSIXErrorDomain && code == Int(ENOENT))
    }
}
