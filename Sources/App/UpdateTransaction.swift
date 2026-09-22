import Foundation

/// Paths are positional arguments, never interpolated shell source.
struct UpdateTransaction {
    let work: URL
    let staged: URL
    let destination: URL
    let backup: URL

    static func preserveDownload(_ download: URL, temporaryDirectory: URL = FileManager.default.temporaryDirectory) throws -> (work: URL, archive: URL) {
        let work = temporaryDirectory.appendingPathComponent("VitalsUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let archive = work.appendingPathComponent("update.zip")
        do { try FileManager.default.moveItem(at: download, to: archive) }
        catch { try? FileManager.default.removeItem(at: work); throw error }
        return (work, archive)
    }

    func arguments(waitForPID: Int32, launch: Bool = true) -> [String] {
        ["-c", Self.script, "vitals-update", String(waitForPID), staged.path, destination.path, backup.path, work.path, launch ? "1" : "0"]
    }

    /// The old bundle is renamed, not deleted. Any failed swap/launch restores it.
    /// The backup is retained after a successful swap so recovery is still possible after a crash.
    static let script = #"""
    owner_pid=$1
    staged=$2
    destination=$3
    backup=$4
    work=$5
    launch=$6
    moved_old=0
    installed_new=0
    committed=0
    cleanup() {
        status=$?
        trap - EXIT HUP INT TERM
        if [ "$committed" -ne 1 ] && [ "$moved_old" -eq 1 ]; then
            if [ "$installed_new" -eq 1 ]; then /bin/rm -rf -- "$destination"; fi
            /bin/mv -- "$backup" "$destination" || exit 2
        fi
        /bin/rm -rf -- "$staged" "$work"
        exit "$status"
    }
    trap cleanup EXIT
    trap 'exit 1' HUP INT TERM
    if [ "$owner_pid" -gt 1 ]; then
        attempts=0
        while kill -0 "$owner_pid" 2>/dev/null; do
            attempts=$((attempts + 1))
            [ "$attempts" -lt 300 ] || exit 1
            /bin/sleep 0.2
        done
    fi
    [ -d "$staged" ] && [ -d "$destination" ] && [ ! -e "$backup" ] || exit 1
    /bin/mv -- "$destination" "$backup" || exit 1
    moved_old=1
    /bin/mv -- "$staged" "$destination" || exit 1
    installed_new=1
    if [ "$launch" = 1 ]; then /usr/bin/open "$destination" || exit 1; fi
    committed=1
    """#
}
