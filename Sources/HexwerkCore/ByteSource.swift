import Foundation

/// Read-only view of a file via mmap. The file is never read as a whole;
/// pages are faulted in on access.
///
/// Gotcha: if another process truncates the file while it is mapped, touching
/// the lost pages raises SIGBUS. Detecting external changes is
/// the guard against that, not this type.
public final class ByteSource: @unchecked Sendable {
    // @unchecked: base and count never change after init, the mapping is
    // read-only, so concurrent reads are safe.
    public let url: URL
    public let count: UInt64
    private let base: UnsafeRawPointer?

    public init(url: URL) throws {
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
        count = UInt64(st.st_size)

        // mmap rejects length 0, an empty file simply has no mapping.
        if count == 0 {
            base = nil
            return
        }
        let p = mmap(nil, Int(count), PROT_READ, MAP_PRIVATE, fd, 0)
        guard let p, p != MAP_FAILED else { throw ByteSourceError.map(url.path, errno) }
        base = UnsafeRawPointer(p)
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
