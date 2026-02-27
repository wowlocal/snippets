import Foundation

enum ChromiumBundleIDSettings {
    private static let additionalBundleIDsDefaultsKey = "chromiumAdditionalBundleIDs"

    private static let builtInExactBundleIDs: Set<String> = [
        "org.chromium.chromium",
        "com.microsoft.edgemac",
        "com.brave.browser",
        "com.operasoftware.opera",
        "com.vivaldi.vivaldi",
        "company.thebrowser.browser"
    ]

    static func isChromiumFamily(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bundleIdentifier.isEmpty else {
            return false
        }

        let normalized = bundleIdentifier.lowercased()
        if normalized.hasPrefix("com.google.chrome") {
            return true
        }

        if builtInExactBundleIDs.contains(normalized) {
            return true
        }

        return Set(additionalBundleIDs().map { $0.lowercased() }).contains(normalized)
    }

    static func additionalBundleIDs() -> [String] {
        let stored = UserDefaults.standard.array(forKey: additionalBundleIDsDefaultsKey) as? [String] ?? []
        return normalizedBundleIDs(from: stored)
    }

    static func saveAdditionalBundleIDs(_ bundleIDs: [String]) {
        let normalized = normalizedBundleIDs(from: bundleIDs)

        if normalized.isEmpty {
            UserDefaults.standard.removeObject(forKey: additionalBundleIDsDefaultsKey)
        } else {
            UserDefaults.standard.set(normalized, forKey: additionalBundleIDsDefaultsKey)
        }
    }

    static func normalizedBundleIDs(from text: String) -> [String] {
        let separators = CharacterSet.newlines.union(CharacterSet(charactersIn: ",;"))
        return normalizedBundleIDs(from: text.components(separatedBy: separators))
    }

    private static func normalizedBundleIDs(from rawValues: [String]) -> [String] {
        var seen = Set<String>()
        var normalized: [String] = []

        for value in rawValues {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let key = trimmed.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            normalized.append(trimmed)
        }

        return normalized
    }
}
