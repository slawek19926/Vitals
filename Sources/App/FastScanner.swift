// FastScanner.swift - szybkie skanowanie drzewa katalogów przez getattrlistbulk (masowy odczyt atrybutów) + równoległość
import Foundation

enum FastScanner {
    struct Partial {
        var categories: [FileCategory: UInt64] = [:]
        var files = 0
        var largest: [(String, UInt64)] = []
        var dirs: [FSNode] = []
    }

    /// Katalogi pomijane, gdy nie leżą na ścieżce skanowanego korzenia
    static let skipPrefixes = ["/System/Volumes", "/Volumes", "/dev", "/private/var/vm",
                               "/Library/Developer/CoreSimulator/Volumes", "/private/var/db/uuidtext",
                               "/private/var/run/com.apple.security.cryptexd"]

    /// Wszystkie punkty montowania w systemie (także ukryte przed Finderem)
    static func allMountPoints() -> [String] {
        var ptr: UnsafeMutablePointer<statfs>? = nil
        let n = getmntinfo(&ptr, MNT_NOWAIT)
        guard n > 0, let ptr else { return [] }
        return (0..<Int(n)).map { i in
            var entry = ptr[i]
            return withUnsafePointer(to: &entry.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
        }
    }

    /// Zbiór katalogów, w które nie schodzimy: obce woluminy i katalogi systemowe spoza korzenia
    private static func exclusions(root: String) -> Set<String> {
        var out = Set<String>()
        for m in allMountPoints() where m != root && m != "/" {
            // nie wykluczaj woluminu, wewnątrz którego zaczynamy skanowanie
            if root == m || root.hasPrefix(m + "/") { continue }
            out.insert(m)
        }
        return out
    }

    /// Skanuje katalog; równolegle na pierwszych dwóch poziomach
    static func scan(_ rootPath: String, shouldCancel: @escaping () -> Bool, progress: @escaping (Int, UInt64) -> Void) -> ScanResult {
        let rootPath = rootPath.count > 1 && rootPath.hasSuffix("/") ? String(rootPath.dropLast()) : rootPath
        let excluded = exclusions(root: rootPath)
        let root = FSNode(name: (rootPath as NSString).lastPathComponent.isEmpty ? rootPath : (rootPath as NSString).lastPathComponent, path: rootPath, isDir: true, parent: nil)
        let res = ScanResult(root: root)
        let counter = Counter()
        let reporter = DispatchSource.makeTimerSource(queue: .global())
        reporter.schedule(deadline: .now() + 0.4, repeating: 0.4)
        reporter.setEventHandler { progress(counter.files, counter.bytes) }
        reporter.resume()

        // poziom 1: wpisy katalogu głównego
        var partial = Partial()
        let level1 = readDirectory(root, into: &partial, counter: counter, root: rootPath, excluded: excluded, shouldCancel: shouldCancel)
        // poziom 2+: równolegle po podkatalogach
        let group = DispatchGroup()
        let lock = NSLock()
        var partials: [Partial] = [partial]
        let queue = DispatchQueue(label: "scan", qos: .userInitiated, attributes: .concurrent)
        let sem = DispatchSemaphore(value: max(2, min(8, ProcessInfo.processInfo.activeProcessorCount)))
        for dir in level1 {
            group.enter()
            queue.async {
                sem.wait()
                var p = Partial()
                scanRecursive(dir, into: &p, counter: counter, root: rootPath, excluded: excluded, shouldCancel: shouldCancel)
                sem.signal()
                lock.lock(); partials.append(p); lock.unlock()
                group.leave()
            }
        }
        group.wait()
        reporter.cancel()

        // scalanie
        var largest: [(String, UInt64)] = []
        var dirs: [FSNode] = []
        for p in partials {
            for (k, v) in p.categories { res.categories[k, default: 0] += v }
            res.files += p.files
            largest += p.largest
            dirs += p.dirs
        }
        func total(_ n: FSNode) -> UInt64 {
            if !n.isDir { return n.size }
            var s = n.smallFiles
            for c in n.children { s += total(c) }
            n.size = s
            return s
        }
        _ = total(root)
        res.deniedDirs = counter.denied
        res.dirs = dirs.filter { $0 !== root }.sorted { $0.size > $1.size }
        res.largestFiles = Array(largest.sorted { $0.1 > $1.1 }.prefix(25))
        return res
    }

    private static func scanRecursive(_ dir: FSNode, into p: inout Partial, counter: Counter, root: String, excluded: Set<String>, shouldCancel: () -> Bool) {
        if shouldCancel() { return }
        let subdirs = readDirectory(dir, into: &p, counter: counter, root: root, excluded: excluded, shouldCancel: shouldCancel)
        for d in subdirs { scanRecursive(d, into: &p, counter: counter, root: root, excluded: excluded, shouldCancel: shouldCancel) }
    }

    /// Czyta jeden katalog przez getattrlistbulk; zwraca podkatalogi do dalszego zejścia
    private static func readDirectory(_ dir: FSNode, into p: inout Partial, counter: Counter, root: String, excluded: Set<String>, shouldCancel: () -> Bool) -> [FSNode] {
        if dir.path != root {
            if excluded.contains(dir.path) { return [] }
            // katalogi systemowe pomijamy tylko wtedy, gdy korzeń skanowania leży poza nimi
            if skipPrefixes.contains(where: { dir.path.hasPrefix($0) && !root.hasPrefix($0) }) { return [] }
        }
        let fd = open(dir.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else {
            if errno == EACCES || errno == EPERM { counter.addDenied() }
            return []
        }
        defer { close(fd) }
        var attrs = attrlist()
        attrs.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrs.commonattr = attrgroup_t(truncatingIfNeeded: ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(truncatingIfNeeded: ATTR_CMN_NAME) | attrgroup_t(truncatingIfNeeded: ATTR_CMN_ERROR) | attrgroup_t(truncatingIfNeeded: ATTR_CMN_OBJTYPE)
        attrs.fileattr = attrgroup_t(truncatingIfNeeded: ATTR_FILE_ALLOCSIZE)
        let bufSize = 256 * 1024
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 8)
        defer { buf.deallocate() }
        var subdirs: [FSNode] = []
        p.dirs.append(dir)
        while true {
            if shouldCancel() { break }
            let n = withUnsafeMutablePointer(to: &attrs) { getattrlistbulk(fd, UnsafeMutableRawPointer($0), buf, bufSize, UInt64(UInt32(bitPattern: FSOPT_PACK_INVAL_ATTRS))) }
            if n <= 0 { break }
            var entry = buf
            for _ in 0..<Int(n) {
                let length = Int(entry.load(as: UInt32.self))
                var field = entry + 4
                let returned = field.load(as: attribute_set_t.self)
                field += MemoryLayout<attribute_set_t>.size
                // kolejność pól: RETURNED_ATTRS, ERROR, NAME, OBJTYPE, ..., atrybuty pliku
                var hadError = false
                if returned.commonattr & attrgroup_t(truncatingIfNeeded: ATTR_CMN_ERROR) != 0 {
                    hadError = field.load(as: UInt32.self) != 0
                    field += 4
                }
                var name = ""
                if returned.commonattr & attrgroup_t(truncatingIfNeeded: ATTR_CMN_NAME) != 0 {
                    let ref = field.load(as: attrreference_t.self)
                    let namePtr = (field + Int(ref.attr_dataoffset)).assumingMemoryBound(to: CChar.self)
                    name = String(cString: namePtr)
                    field += MemoryLayout<attrreference_t>.size
                }
                var objType: fsobj_type_t = 0
                if returned.commonattr & attrgroup_t(truncatingIfNeeded: ATTR_CMN_OBJTYPE) != 0 {
                    objType = field.load(as: fsobj_type_t.self)
                    field += MemoryLayout<fsobj_type_t>.size
                }
                var alloc: UInt64 = 0
                if returned.fileattr & attrgroup_t(truncatingIfNeeded: ATTR_FILE_ALLOCSIZE) != 0 {
                    alloc = UInt64(bitPattern: Int64(field.load(as: off_t.self)))
                    field += MemoryLayout<off_t>.size
                }
                entry += length
                guard !hadError, !name.isEmpty else { continue }
                let path = dir.path == "/" ? "/" + name : dir.path + "/" + name
                if objType == UInt32(VDIR.rawValue) {
                    let n = FSNode(name: name, path: path, isDir: true, parent: dir)
                    dir.children.append(n)
                    subdirs.append(n)
                } else if objType == UInt32(VREG.rawValue) {
                    counter.add(1, alloc)
                    p.files += 1
                    let ext = (name as NSString).pathExtension
                    p.categories[FileCategory.of(path: path, ext: ext), default: 0] += alloc
                    if alloc >= 1_000_000 {
                        let f = FSNode(name: name, path: path, isDir: false, parent: dir); f.size = alloc
                        dir.children.append(f)
                        if p.largest.count < 60 || alloc > p.largest.last!.1 {
                            p.largest.append((path, alloc)); p.largest.sort { $0.1 > $1.1 }
                            if p.largest.count > 60 { p.largest.removeLast() }
                        }
                    } else { dir.smallFiles += alloc; dir.smallCount += 1 }
                }
                // dowiązania symboliczne i inne typy pomijamy
            }
        }
        return subdirs
    }

    final class Counter {
        private var f = 0, b: UInt64 = 0, den = 0
        private let lock = NSLock()
        var files: Int { lock.lock(); defer { lock.unlock() }; return f }
        var bytes: UInt64 { lock.lock(); defer { lock.unlock() }; return b }
        var denied: Int { lock.lock(); defer { lock.unlock() }; return den }
        func add(_ files: Int, _ bytes: UInt64) { lock.lock(); f += files; b += bytes; lock.unlock() }
        func addDenied() { lock.lock(); den += 1; lock.unlock() }
    }
}
