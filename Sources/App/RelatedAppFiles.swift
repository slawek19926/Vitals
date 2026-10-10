import Foundation

/// Untrusted bundle metadata must never select a shared Library directory.
enum RelatedAppFiles {
    static func candidates(home: String, name: String, bundleID: String) -> [String] {
        func component(_ s: String) -> Bool {
            !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && s != "." && s != ".."
                && !s.contains("/") && !s.contains("\\") && !s.contains("\0")
        }
        guard component(bundleID), component(name) else { return [] }
        let entries = [
            ("Application Support", name), ("Application Support", bundleID),
            ("Caches", bundleID), ("Preferences", bundleID + ".plist"),
            ("Containers", bundleID), ("Logs", name), ("Logs", bundleID),
            ("Saved Application State", bundleID + ".savedState"),
            ("HTTPStorages", bundleID), ("WebKit", bundleID), ("Cookies", bundleID + ".binarycookies")
        ]
        return Array(Set(entries.compactMap { directory, leaf -> String? in
            let base = URL(fileURLWithPath: home).appendingPathComponent("Library").appendingPathComponent(directory)
            let target = base.appendingPathComponent(leaf)
            // Reject symlinks escaping the expected parent, including links to the parent itself.
            guard target.resolvingSymlinksInPath().deletingLastPathComponent() == base.resolvingSymlinksInPath() else { return nil }
            return target.path
        })).sorted()
    }
}
