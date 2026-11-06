import Foundation
import Testing
@testable import HexwerkCore

@Suite struct CalculatorTests {
    func ev(_ s: String, _ vars: [String: UInt64] = [:]) throws -> UInt64 { try Calculator.evaluate(s, variables: vars) }

    @Test func arithmeticAndPrecedence() throws {
        #expect(try ev("1 + 2 * 3") == 7)
        #expect(try ev("(1 + 2) * 3") == 9)
        #expect(try ev("0x10 + 0b101 + 0o17 + 10") == 16 + 5 + 15 + 10)
        #expect(try ev("1 << 4 | 3") == 19)
        #expect(try ev("0xFF & ~0x0F") == 0xF0)
        #expect(try ev("2 ** 3 ** 2") == 512)
        #expect(try ev("0x1000_0000 - 1") == 0x0FFF_FFFF)
        #expect(try ev("1Fh") == 31)
        #expect(try ev("'A'") == 65)
        #expect(try ev("'MZ'") == 0x4D5A)
        #expect(try ev("17 % 5") == 2)
    }

    @Test func signedAndWrapping() throws {
        #expect(try ev("-1") == .max)
        #expect(try ev("-7 / 2") == UInt64(bitPattern: -3))
        #expect(try ev("0xFFFFFFFFFFFFFFFF + 1") == 0)
        #expect(try ev("1 << 64") == 0)
        #expect(throws: Calculator.CalcError.self) { try ev("1 / 0") }
        #expect(throws: Calculator.CalcError.self) { try ev("(1 + 2") }
        #expect(throws: Calculator.CalcError.self) { try ev("1 +") }
        #expect(throws: Calculator.CalcError.self) { try ev("foo") }
    }

    @Test func variables() throws {
        #expect(try ev("pos + sel", ["pos": 0x100, "sel": 0x20]) == 0x120)
        #expect(try ev("U32 >> 8", ["u32": 0xAABBCCDD]) == 0xAABBCC)
    }

    @Test func views() {
        let v = Calculator.Views(UInt64(bitPattern: -2), bits: 16)
        #expect(v.unsigned == "65534" && v.signed == "-2" && v.hex == "0xFFFE")
        #expect(v.binary == "1111 1111 1111 1110")
        #expect(Calculator.Views(0x3F80_0000, bits: 32).float32 == "1.0")
        #expect(Calculator.Views(0x4142, bits: 16).ascii == "AB")
    }
}
