import Foundation

// `SnippetLibraryCodec` normally gets this narrowly scoped helper from
// LibraryGeneration.swift. Android reuses the codec without pulling the filesystem
// transaction implementation (and its Darwin locking API) into the JNI module.
nonisolated extension NSError {
    var isFileNotFound: Bool {
        if domain == NSCocoaErrorDomain {
            return code == NSFileNoSuchFileError || code == NSFileReadNoSuchFileError
        }
        return domain == NSPOSIXErrorDomain && code == 2 // ENOENT
    }
}
