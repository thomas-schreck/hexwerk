import Foundation

/// Bytes as pixels for the image view (SPEC FR-11.1): finds bitmaps,
/// fonts, sprites and structure in binaries.
public enum PixelFormat: String, CaseIterable, Sendable {
    case gray8 = "Gray 8", gray16 = "Gray 16 LE", mono1 = "1 bit"
    case rgb24 = "RGB 24", bgr24 = "BGR 24", rgba32 = "RGBA 32", bgra32 = "BGRA 32", argb32 = "ARGB 32"
    case rgb565 = "RGB565 LE"

    /// Bits per pixel.
    /// Localized label; `rawValue` is stored in settings and stays stable.
    public var title: String {
        switch self {
        case .gray8: L("Gray 8")
        case .gray16: L("Gray 16 LE")
        case .mono1: L("1 bit")
        default: rawValue
        }
    }

    public var bits: Int {
        switch self {
        case .mono1: 1
        case .gray8: 8
        case .gray16, .rgb565: 16
        case .rgb24, .bgr24: 24
        case .rgba32, .bgra32, .argb32: 32
        }
    }

    /// Bytes needed for `pixels` pixels (rounded up).
    public func bytes(forPixels pixels: Int) -> Int { (pixels * bits + 7) / 8 }

    /// Byte offset (relative) of pixel `i`.
    public func byteOffset(ofPixel i: Int) -> Int { i * bits / 8 }

    /// RGBA8 (premultiplied alpha = 255 except for formats with alpha,
    /// which are shown opaque so that alpha 0 does not hide data).
    /// Missing bytes at the end stay transparent.
    public func rgba(_ data: Data, width: Int) -> (pixels: [UInt8], width: Int, height: Int) {
        let w = max(1, width)
        let count = bits == 1 ? data.count * 8 : data.count * 8 / bits
        let h = max(1, (count + w - 1) / w)
        var out = [UInt8](repeating: 0, count: w * h * 4)
        data.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
            out.withUnsafeMutableBufferPointer { o in
                func put(_ i: Int, _ r: UInt8, _ g: UInt8, _ bl: UInt8) {
                    o[4 * i] = r; o[4 * i + 1] = g; o[4 * i + 2] = bl; o[4 * i + 3] = 255
                }
                for i in 0 ..< count {
                    switch self {
                    case .gray8: put(i, b[i], b[i], b[i])
                    case .gray16: let v = b[2 * i + 1]; put(i, v, v, v)          // high byte of LE value
                    case .mono1:
                        let v: UInt8 = b[i / 8] >> (7 - UInt8(i % 8)) & 1 == 1 ? 255 : 0
                        put(i, v, v, v)
                    case .rgb24: put(i, b[3 * i], b[3 * i + 1], b[3 * i + 2])
                    case .bgr24: put(i, b[3 * i + 2], b[3 * i + 1], b[3 * i])
                    case .rgba32: put(i, b[4 * i], b[4 * i + 1], b[4 * i + 2])
                    case .bgra32: put(i, b[4 * i + 2], b[4 * i + 1], b[4 * i])
                    case .argb32: put(i, b[4 * i + 1], b[4 * i + 2], b[4 * i + 3])
                    case .rgb565:
                        let v = UInt16(b[2 * i]) | UInt16(b[2 * i + 1]) << 8
                        let r = UInt8(v >> 11 & 0x1F), g = UInt8(v >> 5 & 0x3F), bl = UInt8(v & 0x1F)
                        put(i, r << 3 | r >> 2, g << 2 | g >> 4, bl << 3 | bl >> 2)
                    }
                }
            }
        }
        return (out, w, h)
    }
}
