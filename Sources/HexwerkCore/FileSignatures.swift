import Foundation

/// Magic-byte signatures of common formats. Detection at
/// offset 0 picks the Kaitai format; the same table finds files embedded
/// anywhere in a larger file (firmware images, polyglots), like binwalk.
public struct FileSignature: Sendable {
    /// English name, stable across languages (JSON output); `title` for display.
    public let name: String
    public var title: String { L10n.translate(name) }
    /// Format id in kaitai_struct_formats, if one exists.
    public let kaitai: String?
    public let ext: String
    let magic: [UInt8?]  // nil = any byte
    let offset: Int  // where the magic sits relative to the file start
    /// Embedded scanning only uses signatures that are specific enough.
    let embeddable: Bool
    /// Extra plausibility check; gets the bytes from the file start (up to 4 KiB).
    let check: (@Sendable (Data) -> Bool)?

    init(
        _ name: String, _ kaitai: String?, _ ext: String, _ magic: [UInt8?], at offset: Int = 0,
        embed: Bool = true, check: (@Sendable (Data) -> Bool)? = nil
    ) {
        self.name = name
        self.kaitai = kaitai
        self.ext = ext
        self.magic = magic
        self.offset = offset
        // Short magics only with an extra check, or false positives swamp the list.
        embeddable =
            embed && (magic.count >= 4 || magic.count == 3 && check != nil)
            && magic.prefix(2).allSatisfy { $0 != nil }
        self.check = check
    }

    init(
        _ name: String, _ kaitai: String?, _ ext: String, _ text: String, at offset: Int = 0,
        embed: Bool = true, check: (@Sendable (Data) -> Bool)? = nil
    ) {
        self.init(name, kaitai, ext, Array(text.utf8).map { Optional($0) }, at: offset, embed: embed, check: check)
    }

    func matches(_ head: Data) -> Bool {
        guard head.count >= offset + magic.count else { return false }
        let base = head.startIndex + offset
        for (i, m) in magic.enumerated() where m != nil && head[base + i] != m! { return false }
        return check?(head) ?? true
    }
}

public struct SignatureHit: Sendable, Equatable {
    public var title: String { L10n.translate(name) }
    public let offset: UInt64
    public let name: String
    public let kaitai: String?
    public let ext: String
}

public enum FileSignatures {
    static func b(_ v: Int...) -> [UInt8?] { v.map { $0 < 0 ? nil : UInt8($0) } }

    private static func u16le(_ d: Data, _ o: Int) -> Int {
        d.count >= o + 2 ? Int(d[d.startIndex + o]) | Int(d[d.startIndex + o + 1]) << 8 : -1
    }
    private static func u32le(_ d: Data, _ o: Int) -> Int {
        d.count >= o + 4 ? (0 ..< 4).reduce(0) { $0 | Int(d[d.startIndex + o + $1]) << (8 * $1) } : -1
    }

    /// Ordered from specific to generic: the first match at offset 0 wins.
    public static let all: [FileSignature] = [
        // Images
        .init(LKey("PNG image"), "png", "png", b(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)),
        .init(
            LKey("JPEG image"), "jpeg", "jpg", b(0xFF, 0xD8, 0xFF), embed: true,
            check: { $0.count > 3 && [0xE0, 0xE1, 0xE2, 0xDB, 0xEE, 0xC0, 0xC4, 0xFE].contains($0[$0.startIndex + 3]) }),
        .init(
            LKey("GIF image"), "gif", "gif", "GIF8",
            check: { $0.count > 5 && ($0[$0.startIndex + 4] == 0x37 || $0[$0.startIndex + 4] == 0x39) }),
        .init(LKey("WebP image"), "webp", "webp", b(0x52, 0x49, 0x46, 0x46, -1, -1, -1, -1, 0x57, 0x45, 0x42, 0x50)),
        .init(
            LKey("BMP image"), "bmp", "bmp", "BM", embed: false,
            check: { u32le($0, 14) == 12 || u32le($0, 14) == 40 || u32le($0, 14) >= 52 && u32le($0, 14) <= 124 }),
        .init(LKey("TIFF image (LE)"), "exif", "tif", b(0x49, 0x49, 0x2A, 0x00)),
        .init(LKey("TIFF image (BE)"), "exif", "tif", b(0x4D, 0x4D, 0x00, 0x2A)),
        .init(LKey("Windows icon"), "ico", "ico", b(0x00, 0x00, 0x01, 0x00), embed: false, check: { (1 ... 64).contains(u16le($0, 4)) }),
        .init("Photoshop", nil, "psd", "8BPS"),
        .init(LKey("ICC color profile"), "icc_4", "icc", "acsp", at: 36),
        .init(LKey("GIMP brush"), "gimp_brush", "gbr", "GIMP", at: 20),
        .init("Windows Metafile", "wmf", "wmf", b(0xD7, 0xCD, 0xC6, 0x9A)),
        .init(
            LKey("PCX image"), "pcx", "pcx", b(0x0A), embed: false,
            check: { $0.count > 2 && [0, 2, 3, 4, 5].contains($0[$0.startIndex + 1]) && $0[$0.startIndex + 2] == 1 }),
        .init(LKey("QOI image"), nil, "qoi", "qoif"),
        .init("JPEG 2000", nil, "jp2", b(0x00, 0x00, 0x00, 0x0C, 0x6A, 0x50, 0x20, 0x20)),
        .init(
            LKey("HEIF/AVIF image"), "quicktime_mov", "heic", "ftyp", at: 4,
            check: {
                guard $0.count >= 12 else { return false }
                let brand = String(decoding: $0[($0.startIndex + 8) ..< ($0.startIndex + 12)], as: UTF8.self)
                return ["heic", "heix", "mif1", "avif", "msf1"].contains(brand)
            }),
        // Audio / video
        .init(LKey("WAV audio"), "wav", "wav", b(0x52, 0x49, 0x46, 0x46, -1, -1, -1, -1, 0x57, 0x41, 0x56, 0x45)),
        .init(LKey("AVI video"), "avi", "avi", b(0x52, 0x49, 0x46, 0x46, -1, -1, -1, -1, 0x41, 0x56, 0x49, 0x20)),
        .init(LKey("RIFF container"), "riff", "riff", "RIFF"),
        .init("MP4/QuickTime", "quicktime_mov", "mp4", "ftyp", at: 4),
        .init(LKey("Ogg container"), "ogg", "ogg", "OggS"),
        .init(LKey("FLAC audio"), nil, "flac", "fLaC"),
        .init(LKey("MP3 with ID3v2.4"), "id3v2_4", "mp3", b(0x49, 0x44, 0x33, 0x04)),
        .init(LKey("MP3 with ID3v2.3"), "id3v2_3", "mp3", b(0x49, 0x44, 0x33, 0x03)),
        .init(LKey("MIDI file"), "standard_midi_file", "mid", "MThd"),
        .init(LKey("Sun audio"), "au", "au", ".snd"),
        .init("Creative Voice", "creative_voice_file", "voc", "Creative Voice File"),
        .init("Matroska/WebM", nil, "mkv", b(0x1A, 0x45, 0xDF, 0xA3)),
        .init("Flash (SWF)", "swf", "swf", "FWS", embed: false),
        .init("Flash (SWF, zlib)", "swf", "swf", "CWS", embed: false),
        .init(LKey("IVF video"), "vp8_duck_ivf", "ivf", "DKIF"),
        // Archives / compression
        .init(LKey("ZIP archive"), "zip", "zip", b(0x50, 0x4B, 0x03, 0x04)),
        .init(LKey("ZIP (empty)"), "zip", "zip", b(0x50, 0x4B, 0x05, 0x06), embed: false),
        .init("gzip", "gzip", "gz", b(0x1F, 0x8B, 0x08), check: { $0.count > 3 && $0[$0.startIndex + 3] & 0xE0 == 0 }),
        .init(
            "bzip2", nil, "bz2", "BZh",
            check: {
                $0.count > 9 && (0x31 ... 0x39).contains($0[$0.startIndex + 3])
                    && $0[($0.startIndex + 4) ..< ($0.startIndex + 10)] == Data([0x31, 0x41, 0x59, 0x26, 0x53, 0x59])
            }),
        .init("xz", nil, "xz", b(0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00)),
        .init("Zstandard", nil, "zst", b(0x28, 0xB5, 0x2F, 0xFD)),
        .init(LKey("LZ4 frame"), nil, "lz4", b(0x04, 0x22, 0x4D, 0x18)),
        .init("7-Zip", nil, "7z", b(0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C)),
        .init(LKey("RAR archive"), "rar", "rar", b(0x52, 0x61, 0x72, 0x21, 0x1A, 0x07)),
        .init(LKey("LZH archive"), "lzh", "lzh", "-lh", at: 2, embed: false),
        .init(LKey("tar archive"), nil, "tar", "ustar", at: 257),
        .init(LKey("cpio (old, LE)"), "cpio_old_le", "cpio", b(0xC7, 0x71), embed: false),
        .init("cpio (newc)", nil, "cpio", "070701"),
        .init(LKey("XAR archive"), "xar", "xar", "xar!"),
        .init("Microsoft Cabinet", nil, "cab", "MSCF"),
        .init(LKey("RPM package"), "rpm", "rpm", b(0xED, 0xAB, 0xEE, 0xDB)),
        .init(LKey("Debian package (ar)"), nil, "deb", "!<arch>\n"),
        .init(LKey("Mozilla archive"), "mozilla_mar", "mar", "MAR1"),
        .init("zchunk", "zchunk", "zck", b(0x00, 0x5A, 0x43, 0x4B, 0x31)),
        // Executables
        .init(
            LKey("ELF executable"), "elf", "elf", b(0x7F, 0x45, 0x4C, 0x46),
            check: { $0.count > 5 && [1, 2].contains($0[$0.startIndex + 4]) && [1, 2].contains($0[$0.startIndex + 5]) }),
        .init(LKey("Mach-O (64-bit)"), "mach_o", "macho", b(0xCF, 0xFA, 0xED, 0xFE)),
        .init(LKey("Mach-O (32-bit)"), "mach_o", "macho", b(0xCE, 0xFA, 0xED, 0xFE)),
        .init(
            "Mach-O Universal", "mach_o_fat", "macho", b(0xCA, 0xFE, 0xBA, 0xBE),
            check: { d in
                // Java classes share CAFEBABE; fat binaries have few architectures.
                d.count > 7 && d[d.startIndex + 4] == 0 && d[d.startIndex + 5] == 0 && d[d.startIndex + 6] == 0
                    && (1 ... 20).contains(d[d.startIndex + 7])
            }),
        .init(LKey("Java class"), "java_class", "class", b(0xCA, 0xFE, 0xBA, 0xBE)),
        .init(
            LKey("Windows PE"), "microsoft_pe", "exe", "MZ",
            check: { d in
                let pe = u32le(d, 0x3C)
                return pe > 0 && pe < d.count - 4 && d[(d.startIndex + pe) ..< (d.startIndex + pe + 4)] == Data([0x50, 0x45, 0, 0])
            }),
        .init(LKey("DOS executable"), "dos_mz", "exe", "MZ", embed: false, check: { u16le($0, 0x18) >= 0x1C || u16le($0, 0x18) == 0 }),
        .init("Android DEX", "dex", "dex", "dex\n0"),
        .init("WebAssembly", nil, "wasm", b(0x00, 0x61, 0x73, 0x6D)),
        .init(LKey("Python bytecode 2.7"), "python_pyc_27", "pyc", b(0x03, 0xF3, 0x0D, 0x0A)),
        .init(LKey("UEFI TE image"), "uefi_te", "efi", "VZ", embed: false),
        .init(LKey("U-Boot image"), "uimage", "uimg", b(0x27, 0x05, 0x19, 0x56)),
        .init(LKey("Android boot image"), "android_img", "img", "ANDROID!"),
        .init(LKey("Android sparse image"), "android_sparse", "img", b(0x3A, 0xFF, 0x26, 0xED)),
        .init("Device Tree Blob", "dtb", "dtb", b(0xD0, 0x0D, 0xFE, 0xED)),
        .init(LKey("UF2 firmware"), "uf2", "uf2", "UF2\n"),
        .init("Broadcom TRX", "broadcom_trx", "trx", "HDR0"),
        .init(LKey("iNES ROM"), "ines", "nes", "NES\u{1A}"),
        // File systems / disks
        .init("SquashFS", nil, "squashfs", "hsqs"),
        .init("CramFS", "cramfs", "cramfs", b(0x45, 0x3D, 0xCD, 0x28)),
        .init("UBIFS", "ubifs", "ubifs", b(0x31, 0x18, 0x10, 0x06)),
        .init(LKey("UBI image"), nil, "ubi", "UBI#"),
        .init("JFFS2", nil, "jffs2", b(0x85, 0x19, 0x03, 0x20), embed: false),
        .init("ISO-9660", "iso9660", "iso", "CD001", at: 0x8001),
        .init(LKey("LUKS container"), "luks", "luks", b(0x4C, 0x55, 0x4B, 0x53, 0xBA, 0xBE)),
        .init("LVM2", "lvm2", "lvm", "LABELONE", at: 0x200),
        .init("ext2/3/4", "ext2", "ext", b(0x53, 0xEF), at: 0x438, embed: false),
        .init(LKey("GPT partition table"), "gpt_partition_table", "img", "EFI PART", at: 0x200),
        .init("VirtualBox VDI", "vdi", "vdi", b(0x7F, 0x10, 0xDA, 0xBE), at: 0x40),
        .init("VMware VMDK", "vmware_vmdk", "vmdk", "KDMV"),
        .init("QCOW2", nil, "qcow2", b(0x51, 0x46, 0x49, 0xFB)),
        .init(
            LKey("FAT file system"), "vfat", "img", b(0x55, 0xAA), at: 510, embed: false,
            check: {
                $0.count > 0x5A
                    && (String(decoding: $0[($0.startIndex + 0x36) ..< ($0.startIndex + 0x39)], as: UTF8.self) == "FAT"
                        || String(decoding: $0[($0.startIndex + 0x52) ..< ($0.startIndex + 0x55)], as: UTF8.self) == "FAT")
            }),
        .init(LKey("MBR partition table"), "mbr_partition_table", "img", b(0x55, 0xAA), at: 510, embed: false),
        // Documents / data
        .init(LKey("PDF document"), nil, "pdf", "%PDF-"),
        .init(LKey("SQLite database"), "sqlite3", "sqlite", "SQLite format 3\0"),
        .init(LKey("OLE2/CFB (legacy Office)"), "microsoft_cfb", "doc", b(0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1)),
        .init(LKey("Windows registry"), "regf", "dat", "regf"),
        .init(LKey("Windows shortcut"), "windows_lnk_file", "lnk", b(0x4C, 0x00, 0x00, 0x00, 0x01, 0x14, 0x02, 0x00)),
        .init("Windows Minidump", "windows_minidump", "dmp", "MDMP"),
        .init("Windows Event Log", "windows_evt_log", "evt", "LfLe", at: 4),
        .init("Windows Resource", "windows_resource_file", "res", b(0x00, 0x00, 0x00, 0x00, 0x20, 0x00, 0x00, 0x00), embed: false),
        .init(LKey("TrueType font"), "ttf", "ttf", b(0x00, 0x01, 0x00, 0x00, 0x00), embed: false),
        .init(LKey("OpenType font"), nil, "otf", "OTTO"),
        .init(LKey("WOFF font"), nil, "woff", "wOFF"),
        .init(LKey("WOFF2 font"), nil, "woff2", "wOF2"),
        .init("Apple .DS_Store", "ds_store", "DS_Store", b(0x00, 0x00, 0x00, 0x01, 0x42, 0x75, 0x64, 0x31)),
        .init("Binary Property List", nil, "plist", "bplist0"),
        .init(LKey("glTF (binary)"), "gltf_binary", "glb", "glTF"),
        .init(LKey("GGUF model"), "gguf", "gguf", "GGUF"),
        .init(LKey("Blender file"), "blender_blend", "blend", "BLENDER"),
        .init("DICOM", "dicom", "dcm", "DICM", at: 128),
        .init("gettext .mo", "gettext_mo", "mo", b(0xDE, 0x12, 0x04, 0x95)),
        .init("gettext .mo (BE)", "gettext_mo", "mo", b(0x95, 0x04, 0x12, 0xDE)),
        .init("Chrome .pak", "chrome_pak", "pak", b(0x05, 0x00, 0x00, 0x00), embed: false),
        .init("DOOM WAD", "doom_wad", "wad", "IWAD"),
        .init("DOOM PWAD", "doom_wad", "wad", "PWAD"),
        .init("Quake PAK", "quake_pak", "pak", "PACK"),
        .init(LKey("systemd journal"), "systemd_journal", "journal", "LPKSHHRH"),
        .init("PCAP (µs)", "pcap", "pcap", b(0xD4, 0xC3, 0xB2, 0xA1)),
        .init("PCAP (µs, BE)", "pcap", "pcap", b(0xA1, 0xB2, 0xC3, 0xD4)),
        .init("PCAP (ns)", "pcap", "pcap", b(0x4D, 0x3C, 0xB2, 0xA1)),
        .init("PCAPNG", nil, "pcapng", b(0x0A, 0x0D, 0x0D, 0x0A)),
        .init(LKey("Netmon capture"), "microsoft_network_monitor_v2", "cap", "GMBU"),
        .init("MCAP", "mcap", "mcap", b(0x89, 0x4D, 0x43, 0x41, 0x50)),
        .init("OpenPGP (armored)", nil, "asc", "-----BEGIN PGP"),
        .init(LKey("PEM certificate/key"), nil, "pem", "-----BEGIN "),
        .init(LKey("OpenSSH key"), nil, "key", "openssh-key-v1\0"),
        .init("Java KeyStore", nil, "jks", b(0xFE, 0xED, 0xFE, 0xED)),
        .init("KeePass 2", nil, "kdbx", b(0x03, 0xD9, 0xA2, 0x9A, 0x67, 0xFB, 0x4B, 0xB5)),
        .init(LKey("Git pack"), nil, "pack", "PACK", embed: false),
        .init(LKey("UTF-8 with BOM"), "utf8_string", "txt", b(0xEF, 0xBB, 0xBF), embed: false),
        .init(LKey("UTF-16 with BOM"), "utf16_with_bom", "txt", b(0xFF, 0xFE), embed: false),
    ]

    /// How many bytes from the start detection needs (largest offset + magic).
    static let headSize = 0x8010

    /// Formats whose signature matches at the start, most specific first.
    public static func detect(_ snap: Snapshot) -> [SignatureHit] {
        let head = snap.read(0 ..< UInt64(headSize))
        return all.filter { $0.matches(head) }.map {
            SignatureHit(offset: 0, name: $0.name, kaitai: $0.kaitai, ext: $0.ext)
        }
    }

    /// Default limit of `scanEmbedded`.
    public static let maxEmbeddedHits = 10_000

    /// Embedded files anywhere in `range` (not at offset 0 of the range).
    /// One pass with a two-byte index over the specific signatures. Stops at
    /// exactly `maxHits` hits (`count >= maxHits`: there may be more).
    public static func scanEmbedded(
        _ snap: Snapshot, range: Range<UInt64>? = nil, maxHits: Int = maxEmbeddedHits,
        isCancelled: () -> Bool = { false },
        progress: (Double) -> Void = { _ in }
    ) -> [SignatureHit] {
        let r = (range ?? 0 ..< snap.count).clamped(to: 0 ..< snap.count)
        var index = [[Int]](repeating: [], count: 65536)
        for (k, s) in all.enumerated() where s.embeddable {
            index[Int(s.magic[0]!) << 8 | Int(s.magic[1]!)].append(k)
        }
        var hits: [SignatureHit] = []
        let chunk: UInt64 = 4 << 20
        var pos = r.lowerBound
        while pos < r.upperBound, hits.count < maxHits {
            if isCancelled() { break }
            let end = min(r.upperBound, pos + chunk)
            let data = snap.read(pos ..< min(snap.count, end + 1))
            data.withUnsafeBytes { buf in
                let n = Int(end - pos)
                // Checked per hit, not per chunk: a hostile file can match at
                // nearly every offset of a 4 MiB chunk.
                for i in 0 ..< n where i + 1 < buf.count && hits.count < maxHits {
                    let cands = index[Int(buf[i]) << 8 | Int(buf[i + 1])]
                    if cands.isEmpty { continue }
                    for k in cands {
                        let s = all[k]
                        let start = pos + UInt64(i)
                        // The file itself (offset 0) is not "embedded".
                        guard start >= UInt64(s.offset) else { continue }
                        let fileStart = start - UInt64(s.offset)
                        if fileStart == 0 { continue }
                        let head = snap.read(fileStart ..< fileStart + 4096)
                        if s.matches(head) {
                            hits.append(SignatureHit(offset: fileStart, name: s.name, kaitai: s.kaitai, ext: s.ext))
                            break
                        }
                    }
                }
            }
            pos = end
            progress(Double(pos - r.lowerBound) / Double(max(1, r.count)))
        }
        return hits
    }
}
