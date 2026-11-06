import Foundation
import Testing
@testable import HexwerkCore

/// #18: Fill Selection builds its bytes quickly, also for large selections.
@Suite struct FillTests {
    @Test func repeatsAndCutsPattern() {
        #expect(FillPattern.bytes(Data([0xDE, 0xAD, 0xBE]), count: 7) == Data([0xDE, 0xAD, 0xBE, 0xDE, 0xAD, 0xBE, 0xDE]))
        #expect(FillPattern.bytes(Data([1, 2, 3, 4]), count: 2) == Data([1, 2]))
        #expect(FillPattern.bytes(Data([9]), count: 3) == Data([9, 9, 9]))
        #expect(FillPattern.bytes(Data([1]), count: 0).isEmpty)
        #expect(FillPattern.bytes(Data(), count: 5).isEmpty)
    }

    @Test func slicedPatternIsHandled() {
        let p = Data([0, 0xAA, 0xBB]).dropFirst()       // non-zero startIndex
        #expect(FillPattern.bytes(p, count: 5) == Data([0xAA, 0xBB, 0xAA, 0xBB, 0xAA]))
        #expect(FillPattern.bytes(Data([0, 7]).dropFirst(), count: 2) == Data([7, 7]))
    }

    @Test func largeFillIsFast() {
        let n = 128 << 20
        let clock = ContinuousClock()
        var out = Data()
        let t = clock.measure { out = FillPattern.bytes(Data([0xDE, 0xAD, 0xBE]), count: n) }
        #expect(out.count == n)
        #expect(out[n - 1] == [0xDE, 0xAD, 0xBE][(n - 1) % 3])
        // One append per repeat took many seconds here; doubling is a handful of memcpys.
        #expect(t < .seconds(2))
    }
}
