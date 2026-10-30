import CryptoKit
import Darwin
import Foundation

let homePath = FileManager.default.homeDirectoryForCurrentUser.path

/// "~/…" for paths under the home folder.
func tildePath(_ path: String) -> String {
    path.hasPrefix(homePath) ? "~" + path.dropFirst(homePath.count) : path
}

func lastComponent(_ path: String) -> String { (path as NSString).lastPathComponent }
func parentPath(_ path: String) -> String { (path as NSString).deletingLastPathComponent }
func exists(_ path: String) -> Bool { access(path, F_OK) == 0 }

func modificationTime(_ path: String) -> Double? {
    var st = stat()
    return lstat(path, &st) == 0 ? Double(st.st_mtimespec.tv_sec) : nil
}

/// Sorted directory listing, hidden entries included. Empty when unreadable.
func children(_ path: String) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted()
}

/// (free, capacity) of the home volume, as Finder reports them.
func volumeSpace() -> (Int64, Int64) {
    let values = try? URL(fileURLWithPath: homePath).resourceValues(
        forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
    return (values?.volumeAvailableCapacityForImportantUsage ?? 0, Int64(values?.volumeTotalCapacity ?? 0))
}

// MARK: - Traversal

enum WalkDecision { case descend, skip }

/// Physical fts traversal: never follows symlinks and never leaves the volume it starts on.
/// Post-order directory visits are not reported.
func walk(_ root: String, maxDepth: Int = .max, _ visit: (UnsafeMutablePointer<FTSENT>) -> WalkDecision) {
    guard let cRoot = strdup(root) else { return }
    defer { free(cRoot) }
    var argv: [UnsafeMutablePointer<CChar>?] = [cRoot, nil]
    guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return }
    defer { fts_close(fts) }
    while let entry = fts_read(fts) {
        let info = Int32(entry.pointee.fts_info)
        if info == FTS_DP { continue }
        let decision = visit(entry)
        if info == FTS_D && (decision == .skip || Int(entry.pointee.fts_level) >= maxDepth) {
            fts_set(fts, entry, FTS_SKIP)
        }
    }
}

extension UnsafeMutablePointer where Pointee == FTSENT {
    var path: String { String(cString: pointee.fts_path) }
    var level: Int { Int(pointee.fts_level) }
    var info: Int32 { Int32(pointee.fts_info) }
    var st: stat? { pointee.fts_statp?.pointee }
}

/// Bytes allocated on disk, counting hard-linked files once (like `du`).
func allocatedSize(_ path: String) -> Int64 {
    var total: Int64 = 0
    var seenInodes = Set<UInt64>()
    walk(path) { entry in
        guard let st = entry.st else { return .descend }
        if entry.info != FTS_D && st.st_nlink > 1 && !seenInodes.insert(st.st_ino).inserted { return .descend }
        total += Int64(st.st_blocks) * 512
        return .descend
    }
    return total
}

/// Newest modification time of anything below `path`.
func newestModification(_ path: String, maxDepth: Int) -> Date? {
    var newest: Double = 0
    walk(path, maxDepth: maxDepth) { entry in
        if let st = entry.st { newest = max(newest, Double(st.st_mtimespec.tv_sec)) }
        return .descend
    }
    return newest > 0 ? Date(timeIntervalSince1970: newest) : nil
}

/// Runs `transform` over `items` on all cores, keeping order.
func concurrentMap<T, R>(_ items: [T], _ transform: (T) -> R) -> [R] {
    var results = [R?](repeating: nil, count: items.count)
    results.withUnsafeMutableBufferPointer { buffer in
        DispatchQueue.concurrentPerform(iterations: items.count) { buffer[$0] = transform(items[$0]) }
    }
    return results.map { $0! }
}

// MARK: - File identity

/// SHA-256 over size plus three 1 MB samples (start, middle, end). Cheap pre-filter for duplicates;
/// `filesIdentical` does the real check before anything is changed.
func sampleHash(_ path: String, size: Int64) -> String? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }
    let chunk: Int64 = 1 << 20
    var hasher = SHA256()
    withUnsafeBytes(of: size) { hasher.update(bufferPointer: $0) }
    for offset in [0, size / 2, max(0, size - chunk)] {
        guard (try? handle.seek(toOffset: UInt64(offset))) != nil,
              let data = try? handle.read(upToCount: Int(chunk)) else { return nil }
        hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

func filesIdentical(_ a: String, _ b: String) -> Bool {
    guard let ha = FileHandle(forReadingAtPath: a), let hb = FileHandle(forReadingAtPath: b) else { return false }
    defer { try? ha.close(); try? hb.close() }
    while true {
        let da = (try? ha.read(upToCount: 8 << 20)) ?? Data()
        let db = (try? hb.read(upToCount: 8 << 20)) ?? Data()
        if da != db { return false }
        if da.isEmpty { return true }
    }
}

/// Bytes of the file not shared with APFS clones. Near zero means it is already a clone.
func privateSize(_ path: String) -> Int64? {
    var request = attrlist()
    request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    request.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
    var buffer = [UInt8](repeating: 0, count: 32)
    let rc = buffer.withUnsafeMutableBytes {
        getattrlist(path, &request, $0.baseAddress, $0.count, UInt32(FSOPT_ATTR_CMN_EXTENDED))
    }
    guard rc == 0 else { return nil }
    // Layout: u_int32_t length, then off_t private size.
    return buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int64.self) }
}

func sameInode(_ a: String, _ b: String) -> Bool {
    var sa = stat(), sb = stat()
    return stat(a, &sa) == 0 && stat(b, &sb) == 0 && sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino
}
