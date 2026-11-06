import Foundation
import Testing
@testable import HexwerkCore
import HexwerkScript

@Suite struct ScriptTests {
    let sample = Data([0x89, 0x50, 0x4E, 0x47, 0x01, 0x02, 0x03, 0x04, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
                      + Array("hello world".utf8))

    private func withDoc(_ body: (Document) throws -> Void) throws {
        let url = try tempFile(sample)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(try Document(url: url))
    }

    @Test func readApi() throws {
        try withDoc { doc in
            let r = ScriptRunner.run("""
                print(hw.size(), hw.hex(0, 4), hw.u8(0), hw.u16(4), hw.u16(4, false), hw.u32(4))
                print(hw.i8(0), hw.i16(8), typeof hw.u64(8), String(hw.u64(8)), String(hw.i64(8)))
                print(hw.str(16, 5), hw.read(1, 3).join(","), hw.find("01 ?? 03"), hw.findText("world"))
                print(hw.cursor, hw.selection.start, hw.selection.end, hw.fileName)
                """, document: doc, context: ScriptContext(cursor: 3, selection: 2..<5, fileName: "x.bin"))
            #expect(r.error == nil)
            #expect(r.output == [
                "27 89 50 4E 47 137 513 258 67305985",
                "-119 -1 bigint 18446744073709551615 -1",
                "hello 80,78,71 4 22",
                "3 2 5 x.bin",
            ])
        }
    }

    @Test func editsAreOneUndoStep() throws {
        try withDoc { doc in
            let r = ScriptRunner.run("""
                hw.write(0, [0x7F, 0x45]); hw.insert(2, "AB"); hw.remove(4, 2)
                hw.write(hw.size() - 1, new Uint8Array([0x21])); hw.select(1, 3); hw.goto(7)
                """, document: doc, context: ScriptContext())
            #expect(r.error == nil && r.edits == 4)
            #expect(doc.read(0..<6) == Data([0x7F, 0x45, 0x41, 0x42, 0x01, 0x02]))
            #expect(doc.read(doc.count - 1 ..< doc.count) == Data("!".utf8))
            #expect(r.select == 1..<3 && r.goTo == 7)
            doc.undo()
            #expect(doc.read(0..<doc.count) == sample)
            #expect(!doc.canUndo)
        }
    }

    @Test func errorRollsBackAndReportsLine() throws {
        try withDoc { doc in
            let r = ScriptRunner.run("hw.write(0, [1, 2, 3])\n\nhw.write(0, [300])\n", document: doc, context: ScriptContext())
            #expect(r.error?.line == 3)
            #expect(r.error?.message.contains("0–255") == true)
            #expect(doc.read(0..<doc.count) == sample && !doc.canUndo && r.edits == 0)
            let r2 = ScriptRunner.run("hw.read(1000, 1)", document: doc, context: ScriptContext())
            #expect(r2.error?.message.contains(L("invalid offset: %@ (size %@)", "1000", "\(sample.count)")) == true)
            let r3 = ScriptRunner.run("syntax error here(", document: doc, context: ScriptContext())
            #expect(r3.error != nil)
        }
    }

    @Test func timeoutAndCancel() throws {
        try withDoc { doc in
            let t0 = Date()
            let r = ScriptRunner.run("while (true) {}", document: doc, context: ScriptContext(), timeout: 0.5)
            #expect(r.error?.isTimeout == true)
            #expect(Date().timeIntervalSince(t0) < 5)
            let r2 = ScriptRunner.run("hw.write(0,[0]); while (true) {}", document: doc, context: ScriptContext(),
                                      isCancelled: { true })
            #expect(r2.error?.message == L("Cancelled") && r2.error?.isTimeout == false)
            #expect(doc.read(0..<1) == Data([0x89]))
        }
    }

    @Test func readOnlyDocumentRejectsWrites() throws {
        let url = try tempFile(sample)
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try Document(url: url, readOnly: true)
        let r = ScriptRunner.run("hw.write(0, [1])", document: doc, context: ScriptContext())
        #expect(r.error?.message.contains(L("Document is read-only")) == true)
    }

    /// The app runs scripts on a working copy and adopts the result.
    @Test func workingCopyAdopt() throws {
        try withDoc { doc in
            try doc.overwrite(at: 0, with: Data([0x11]))
            let base = doc.snapshot()
            let copy = Document(editing: base)
            _ = ScriptRunner.run("hw.insert(0, [0xAA, 0xBB])", document: copy, context: ScriptContext())
            try doc.adopt(copy, base: base)
            #expect(doc.read(0..<3) == Data([0xAA, 0xBB, 0x11]))
            doc.undo()
            #expect(doc.read(0..<2) == Data([0x11, 0x50]))
            doc.undo()
            #expect(doc.read(0..<doc.count) == sample)
            // Adopting fails if the document changed in between.
            let base2 = doc.snapshot()
            let copy2 = Document(editing: base2)
            try copy2.overwrite(at: 0, with: Data([1]))
            try doc.overwrite(at: 1, with: Data([2]))
            #expect(throws: DocumentError.self) { try doc.adopt(copy2, base: base2) }
        }
    }

    @Test func groupedRollsBack() throws {
        try withDoc { doc in
            struct Boom: Error {}
            #expect(throws: Boom.self) {
                try doc.grouped { try doc.overwrite(at: 0, with: Data([0])); throw Boom() }
            }
            #expect(doc.read(0..<doc.count) == sample && !doc.canUndo)
        }
    }

    /// Huge or infinite lengths used to trap in UInt64(_:) and kill the host (#12).
    @Test func hugeLengthsAreClamped() throws {
        try withDoc { doc in
            let n = sample.count
            let r = ScriptRunner.run("""
                print(hw.read(0, 1e20).length, hw.read(0, Infinity).length, hw.read(4, Number.MAX_VALUE).length)
                print(hw.str(16, 1e300), hw.hex(24, Infinity))
                """, document: doc, context: ScriptContext())
            #expect(r.error == nil)
            #expect(r.output == ["\(n) \(n) \(n - 4)", "hello world 72 6C 64"])
            let r2 = ScriptRunner.run("hw.remove(16, Infinity)", document: doc, context: ScriptContext())
            #expect(r2.error == nil && doc.count == 16)
            let r3 = ScriptRunner.run("hw.read(0, NaN)", document: doc, context: ScriptContext())
            #expect(r3.error != nil)
        }
    }
}
