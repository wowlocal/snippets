import Foundation

// Automates the blocking manual check from the frecency spec: writing usage
// data must not trip the file-system monitor that `SnippetStore` installs on
// the support folder. If it did, every expansion would collapse the editor's
// 0.3s write debounce and rewrite the whole library while the user is typing.
//
// Build and run:
//
//   swiftc -O snippets/Core/Snippet.swift snippets/SnippetFrecency.swift \
//          snippets/SnippetUsageDocument.swift \
//          Tests/UsageDirectoryIsolationTests.swift \
//          -o /tmp/usage-isolation-tests && /tmp/usage-isolation-tests

private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    if actual != expected {
        fputs("FAIL: \(message) - expected \(expected), got \(actual)\n", stderr)
        exit(1)
    }
}

private func assertTrue(_ condition: Bool, _ message: String) {
    if !condition {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

/// Mirrors `SnippetStore.startObservingExternalChanges()`: same `O_EVTONLY`
/// descriptor on the folder, same event mask.
private final class FolderMonitor {
    private let descriptor: Int32
    private let source: DispatchSourceFileSystemObject
    private let lock = NSLock()
    private var count = 0

    init?(folder: URL, queue: DispatchQueue) {
        descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.count += 1
            self.lock.unlock()
        }
        source.setCancelHandler { [descriptor] in close(descriptor) }
        source.resume()
    }

    var firedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func cancel() { source.cancel() }
}

/// The monitor delivers on a queue, so give it a moment to catch up before
/// asserting. A false pass here is worse than a slow test.
private func settle(_ queue: DispatchQueue, seconds: Double = 0.6) {
    Thread.sleep(forTimeInterval: seconds)
    queue.sync {}
}

@main
private enum UsageDirectoryIsolationTests {
    static func main() {
        let queue = DispatchQueue(label: "usage-isolation-monitor")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("snippets-isolation-\(UUID().uuidString)", isDirectory: true)
        let usageFolder = root.appendingPathComponent("Usage", isDirectory: true)
        let usageFile = usageFolder.appendingPathComponent("usage.json", isDirectory: false)
        let libraryFile = root.appendingPathComponent("snippets.json", isDirectory: false)

        // Created before the monitor goes up, exactly as `SnippetUsageStore.init`
        // does it relative to `SnippetStore.init`.
        try! FileManager.default.createDirectory(at: usageFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        guard let monitor = FolderMonitor(folder: root, queue: queue) else {
            fputs("FAIL: could not observe the temporary support folder\n", stderr)
            exit(1)
        }
        defer { monitor.cancel() }
        settle(queue)

        let baseline = monitor.firedCount
        var document = SnippetUsageDocument.empty(now: 1_785_312_000)
        for index in 0..<20 {
            document.records[UUID().uuidString] =
                SnippetUsageRecord(weight: Double(index + 1), count: 1, lastUsedAt: 1_785_312_000)
            let wrote = SnippetUsageFile.mergeAndWrite(
                document, liveIDs: nil, now: 1_785_312_000,
                folderURL: usageFolder, fileURL: usageFile)
            assertTrue(wrote, "usage write \(index) succeeded")
        }
        settle(queue)

        assertEqual(monitor.firedCount, baseline,
                    "20 atomic usage writes leave the parent folder's monitor silent")
        assertEqual(document.records.count, 20, "the fixture really did write 20 records")
        assertTrue(FileManager.default.fileExists(atPath: usageFile.path), "the usage file exists")

        // Permissions come from the same write path.
        let attributes = try! FileManager.default.attributesOfItem(atPath: usageFile.path)
        assertEqual((attributes[.posixPermissions] as? NSNumber)?.int16Value, 0o600,
                    "usage data is written owner-only")

        // The negative control. Without this the test above would also pass
        // with a monitor that never fires at all, which would prove nothing.
        try! Data("{}".utf8).write(to: libraryFile, options: .atomic)
        settle(queue)
        assertTrue(monitor.firedCount > baseline,
                   "a write directly into the support folder does fire the monitor")

        print("UsageDirectoryIsolationTests passed")
    }
}
