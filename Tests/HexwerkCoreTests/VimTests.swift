import Foundation
import Testing
@testable import HexwerkCore

@Suite struct VimTests {
    func keys(_ m: inout VimMachine, _ s: String) -> [VimAction] { s.flatMap { m.key($0) } }

    @Test func motionsWithCounts() {
        var m = VimMachine()
        #expect(keys(&m, "l") == [.moveBytes(1)])
        #expect(keys(&m, "5j") == [.moveRows(5)])
        #expect(keys(&m, "12h") == [.moveBytes(-12)])
        #expect(keys(&m, "3w") == [.moveBytes(12)])
        #expect(keys(&m, "0") == [.rowStart])
        #expect(keys(&m, "10") == [])  // count pending, 0 is a digit here
        #expect(m.status == "NORMAL 10")
        #expect(keys(&m, "k") == [.moveRows(-10)])
        #expect(keys(&m, "gg") == [.top])
        #expect(keys(&m, "G") == [.bottom])
        #expect(m.key("f", control: true) == [.movePages(1)])
        #expect(keys(&m, "2") + [m.key("u", control: true)].flatMap { $0 } == [.movePages(-1)])
    }

    @Test func modes() {
        var m = VimMachine()
        #expect(keys(&m, "i") == [.enterInsert(after: false)])
        #expect(m.mode == .insert && !m.handlesTyping)
        #expect(m.escape() == [.enterNormal])
        #expect(keys(&m, "R") == [.enterReplace] && m.mode == .replace)
        _ = m.escape()
        #expect(keys(&m, "v") == [.startVisual] && m.mode == .visual)
        #expect(keys(&m, "3l") == [.moveBytes(3)])
        #expect(keys(&m, "y") == [.yank(count: 0), .endVisual] && m.mode == .normal)
        #expect(keys(&m, "vd") == [.startVisual, .delete(count: 0), .endVisual])
        #expect(keys(&m, "v") == [.startVisual])
        #expect(m.escape() == [.endVisual] && m.mode == .normal)
    }

    @Test func editingAndMarks() {
        var m = VimMachine()
        #expect(keys(&m, "4x") == [.delete(count: 4)])
        #expect(keys(&m, "rA") == [])
        #expect(m.status == "NORMAL rA")
        #expect(keys(&m, "f") == [.replaceByte(0xAF)])
        #expect(keys(&m, "rz") == [.beep])
        #expect(keys(&m, "ma") == [.setMark("a")])
        #expect(keys(&m, "'a") == [.jumpMark("a")])
        #expect(
            keys(&m, "uPp/nN:") == [.undo, .paste(after: false), .paste(after: true), .search, .searchNext, .searchPrevious, .goToPrompt])
        #expect(m.key("r", control: true) == [.redo])
        #expect(keys(&m, "Q") == [.beep])
    }
}
