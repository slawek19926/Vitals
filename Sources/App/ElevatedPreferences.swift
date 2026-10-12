import Foundation
import Darwin

/// Both administrator launch paths pass the same preference file and originating UID.
enum ElevatedPreferences {
    static let bundleIdentifier = "online.equishow.vitals"
    private static let maximumSize = 4 * 1024 * 1024

    static func arguments(home: String = NSHomeDirectory(), uid: uid_t = getuid(),
                          domain: String = bundleIdentifier) -> [String] {
        ["-userPrefs", preferenceURL(home: home, domain: domain).path, "-userUID", String(uid)]
    }

    /// Restore before any theme or localization singleton reads UserDefaults.
    /// Only a regular, user-owned preferences file in that user's home is accepted.
    @discardableResult
    static func restore(arguments: [String] = CommandLine.arguments, effectiveUID: uid_t = geteuid(),
                        defaults: UserDefaults = .standard, domain: String = bundleIdentifier,
                        homeForUID: (uid_t) -> String? = homeDirectory) -> Bool {
        func option(_ name: String) -> String? {
            let matches = arguments.indices.filter { arguments[$0] == name }
            guard matches.count == 1, let index = matches.first, index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        guard effectiveUID == 0,
              let sourcePath = option("-userPrefs"), let uidString = option("-userUID"),
              let sourceUID = uid_t(uidString), sourceUID != 0,
              let home = homeForUID(sourceUID),
              URL(fileURLWithPath: sourcePath).standardizedFileURL == preferenceURL(home: home, domain: domain)
        else { return false }

        // O_NOFOLLOW and fstat validate the file actually read, rather than a racy path check.
        let descriptor = open(sourcePath, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == sourceUID, info.st_size > 0, info.st_size <= maximumSize,
              let data = try? handle.read(upToCount: maximumSize + 1), data.count <= maximumSize,
              let values = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { return false }
        // Replacing the domain also clears stale root-only settings absent from the user's file.
        defaults.setPersistentDomain(values, forName: domain)
        return true
    }

    private static func preferenceURL(home: String, domain: String) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent("Library/Preferences")
            .appendingPathComponent(domain + ".plist").standardizedFileURL
    }

    private static func homeDirectory(_ uid: uid_t) -> String? {
        guard let account = getpwuid(uid), let home = account.pointee.pw_dir else { return nil }
        return String(cString: home)
    }
}
