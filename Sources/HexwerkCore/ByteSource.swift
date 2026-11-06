import Foundation

/// Read-only view of a file via mmap. The file is never read as a whole;
/// pages are faulted in on access.
///
/// When another program truncates or overwrites a mapped file, macOS keeps
/// this private mapping intact by first copying the affected pages into it:
/// for a truncated multi-GB file that costs the other program seconds and
/// the system as much memory. Where the kernel does not see the change (e.g.
/// another host on a network volume), touching lost pages raises SIGBUS.
/// With `privateCopy` the mapping comes from an APFS clone no other program
/// can reach (#80). Where no clone can be made (other file systems, another
/// volume) the file itself is mapped, and detecting external changes
/// is the guard.
public final class ByteSource: @unchecked Sendable {
    // @unchecked: base and count never change after init, the mapping is
    // read-only, so concurrent reads are safe.
    /// The file that was opened (not the clone).
    public let url: URL
    public let count: UInt64
    private let base: UnsafeRawPointer?
    /// True if the mapping comes from a private clone of the file.
    let isClone: Bool
    /// The opened file as checked before cloning, for change detection. A
    /// change between this check and the clone makes it look modified, never
    /// the other way round.
    let stamp: DiskStamp

    public init(url: URL, privateCopy: Bool = false) throws {
        self.url = url
        // Check the type before opening: open() blocks on a FIFO until a
        // writer shows up, and opening a device can have side effects.
        var st = stat()
        guard stat(url.path, &st) == 0 else { throw ByteSourceError.open(url.path, errno) }
        guard (st.st_mode & S_IFMT) == S_IFREG else { throw ByteSourceError.notRegularFile(url.path) }

        // O_NONBLOCK in case the path was swapped for a FIFO after the check;
        // the fstat below catches that. It has no effect on regular files.
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_NOCTTY)
        guard fd >= 0 else { throw ByteSourceError.open(url.path, errno) }
        defer { close(fd) }   // the mapping stays valid after close

        guard fstat(fd, &st) == 0 else { throw ByteSourceError.open(url.path, errno) }
        guard (st.st_mode & S_IFMT) == S_IFREG else { throw ByteSourceError.notRegularFile(url.path) }
        stamp = DiskStamp(st)

        var mapFD = fd
        if privateCopy, st.st_size > 0, let clone = Self.clone(fd) {
            mapFD = clone
            // The clone may hold a newer state than `st` if the file was
            // written meanwhile; its own size is the one that is safe to map.
            guard fstat(clone, &st) == 0 else {
                close(clone)
                throw ByteSourceError.open(url.path, errno)
            }
        }
        isClone = mapFD != fd
        defer { if mapFD != fd { close(mapFD) } }
        count = UInt64(st.st_size)

        // mmap rejects length 0, an empty file simply has no mapping.
        if count == 0 {
            base = nil
            return
        }
        let p = mmap(nil, Int(count), PROT_READ, MAP_PRIVATE, mapFD, 0)
        guard let p, p != MAP_FAILED else { throw ByteSourceError.map(url.path, errno) }
        base = UnsafeRawPointer(p)
    }

    /// Clones the open file into the temp folder and returns a descriptor of
    /// the clone, already unlinked: the mapping keeps it alive and closing
    /// the document frees it, nothing to clean up. nil if the file system
    /// cannot clone (ENOTSUP, EXDEV for another volume) or anything else
    /// fails; the caller then maps the file itself.
    private static func clone(_ fd: Int32) -> Int32? {
        guard let dir = cloneDirectory else { return nil }
        let path = dir.appendingPathComponent("\(getpid())-\(UUID().uuidString)").path
        guard fclonefileat(fd, AT_FDCWD, path, UInt32(CLONE_NOOWNERCOPY)) == 0 else { return nil }
        let clone = open(path, O_RDONLY | O_NOFOLLOW)
        unlink(path)
        return clone >= 0 ? clone : nil
    }

    /// Where clones are made. Clones are unlinked right after opening, so
    /// only a crash in that moment leaves one behind; those of processes
    /// that no longer run are removed the first time this is used.
    static let cloneDirectory: URL? = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hexwerk-clones")
        guard mkdir(dir.path, 0o700) == 0 || errno == EEXIST else { return nil }
        removeStaleClones(in: dir)
        return dir
    }()

    static func removeStaleClones(in dir: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names {
            guard let pid = pid_t(name.prefix { $0 != "-" }) else { continue }
            if kill(pid, 0) != 0 && errno == ESRCH { unlink(dir.appendingPathComponent(name).path) }
        }
    }

    deinit {
        if let base { munmap(UnsafeMutableRawPointer(mutating: base), Int(count)) }
    }

    /// Bytes in `range`, clipped to the file. A range past the end yields
    /// fewer (or no) bytes instead of trapping: offsets come from user input.
    public func read(_ range: Range<UInt64>) -> Data {
        let r = range.clamped(to: 0..<count)
        guard let base, !r.isEmpty else { return Data() }
        return Data(bytes: base + Int(r.lowerBound), count: Int(r.count))
    }

    /// Zero-copy access to the whole mapping (e.g. for YARA scans).
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try body(UnsafeRawBufferPointer(start: base, count: Int(count)))
    }
}

public enum ByteSourceError: Error, CustomStringConvertible {
    case open(String, Int32)
    case map(String, Int32)
    case notRegularFile(String)

    public var description: String {
        switch self {
        case .open(let p, let e): "\(p): \(String(cString: strerror(e)))"
        case .map(let p, let e): "\(p): mmap: \(String(cString: strerror(e)))"
        case .notRegularFile(let p): L("%@: not a regular file", "\(p)")
        }
    }
}
