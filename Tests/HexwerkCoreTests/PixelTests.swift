import Foundation
import Testing
@testable import HexwerkCore

@Suite struct PixelTests {
    func px(_ r: (pixels: [UInt8], width: Int, height: Int), _ i: Int) -> [UInt8] { Array(r.pixels[4 * i ..< 4 * i + 4]) }

    @Test func formats() {
        let rgb = PixelFormat.rgb24.rgba(Data([255, 0, 0, 0, 255, 0, 0, 0, 255]), width: 2)
        #expect(rgb.width == 2 && rgb.height == 2)
        #expect(px(rgb, 0) == [255, 0, 0, 255] && px(rgb, 2) == [0, 0, 255, 255])
        #expect(px(rgb, 3) == [0, 0, 0, 0])                              // missing pixel stays transparent
        #expect(px(PixelFormat.bgr24.rgba(Data([1, 2, 3]), width: 1), 0) == [3, 2, 1, 255])
        #expect(px(PixelFormat.bgra32.rgba(Data([1, 2, 3, 0]), width: 1), 0) == [3, 2, 1, 255])
        #expect(px(PixelFormat.argb32.rgba(Data([0, 1, 2, 3]), width: 1), 0) == [1, 2, 3, 255])
        #expect(px(PixelFormat.rgb565.rgba(Data([0x00, 0xF8]), width: 1), 0) == [255, 0, 0, 255])
        #expect(px(PixelFormat.rgb565.rgba(Data([0xE0, 0x07]), width: 1), 0) == [0, 255, 0, 255])
        #expect(px(PixelFormat.gray16.rgba(Data([0x34, 0x12]), width: 1), 0) == [0x12, 0x12, 0x12, 255])
        let mono = PixelFormat.mono1.rgba(Data([0b1010_0000]), width: 8)
        #expect(mono.height == 1 && px(mono, 0)[0] == 255 && px(mono, 1)[0] == 0 && px(mono, 2)[0] == 255)
    }

    @Test func offsets() {
        #expect(PixelFormat.rgb24.byteOffset(ofPixel: 5) == 15)
        #expect(PixelFormat.mono1.byteOffset(ofPixel: 17) == 2)
        #expect(PixelFormat.mono1.bytes(forPixels: 9) == 2)
        #expect(PixelFormat.rgba32.bytes(forPixels: 3) == 12)
    }
}
