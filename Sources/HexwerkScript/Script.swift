import Foundation
import HexwerkCore
import JavaScriptCore

/// JavaScript automation on JavaScriptCore, which ships with
/// macOS. Scripts see one global `hw` object; see `ScriptRunner.apiHelp`.
public struct ScriptContext: Sendable {
    public var cursor: UInt64
    public var selection: Range<UInt64>?
    public var fileName: String

    public init(cursor: UInt64 = 0, selection: Range<UInt64>? = nil, fileName: String = "") {
        self.cursor = cursor
        self.selection = selection
        self.fileName = fileName
    }
}

public struct ScriptError: Error, CustomStringConvertible, Sendable {
    public let message: String
    public let line: Int?
    public var isTimeout = false

    public init(message: String, line: Int?, isTimeout: Bool = false) {
        self.message = message
        self.line = line
        self.isTimeout = isTimeout
    }

    public var description: String { line.map { L("Line %ld: %@", $0, message) } ?? message }
}

public struct ScriptResult: Sendable {
    public var output: [String] = []
    /// Number of edit calls (write/insert/remove) that changed the document.
    public var edits = 0
    public var select: Range<UInt64>?
    public var goTo: UInt64?
    public var error: ScriptError?
}

public enum ScriptRunner {
    public static let defaultTimeout: Double = 30

    /// One line per API call: signature, padded, then the localized description.
    public static var apiHelp: String {
        [
            ("hw.size()", L("file size")),
            ("hw.read(off, len)", L("bytes as Uint8Array")),
            ("hw.write(off, bytes)", L("overwrite (Array, Uint8Array or String)")),
            ("hw.insert(off, bytes)", L("insert")),
            ("hw.remove(off, len)", L("delete")),
            ("hw.u8/u16/u32/u64(off, le)", L("read unsigned (le = true: little endian, default)")),
            ("hw.i8/i16/i32/i64(off, le)", L("signed; 64 bit as BigInt")),
            ("hw.f32/f64(off, le)", L("floating point")),
            ("hw.str(off, len)", L("UTF-8 text")),
            ("hw.hex(off, len)", L("hex text")),
            (L("hw.find(pattern, start, end)"), L("offsets of a hex pattern (\"DE AD ?? EF\")")),
            ("hw.findText(text)", L("offsets of a UTF-8 text")),
            (L("hw.select(start, end)"), L("set the selection after the run")),
            ("hw.goto(off)", L("set the cursor after the run")),
            ("hw.cursor, hw.selection", L("state at start ({start, end} or null)")),
            ("hw.fileName", L("file name")),
            ("print(...), console.log(...)", L("output")),
        ].map { $0.0.padding(toLength: 31, withPad: " ", startingAt: 0) + $0.1 }.joined(separator: "\n")
    }

    /// Runs `source` against `document` as one undo step; on an error all
    /// edits are rolled back. Blocks the calling thread (runs on its own
    /// large-stack thread). `isCancelled` is polled about every 0.2 s.
    public static func run(_ source: String, name: String = "script.js", document: Document,
                           context: ScriptContext, timeout: Double = defaultTimeout,
                           isCancelled: @escaping @Sendable () -> Bool = { false }) -> ScriptResult {
        onLargeStack {
            let session = Session(document: document, context: context)
            do {
                try document.grouped {
                    try session.evaluate(source, name: name, timeout: timeout, isCancelled: isCancelled)
                }
            } catch let e as ScriptError {
                session.result.error = e
                session.result.edits = 0
            } catch {
                session.result.error = ScriptError(message: String(describing: error), line: nil)
                session.result.edits = 0
            }
            return session.result
        }
    }
}

/// One script run: the JS context, the `hw` bridge, collected results.
private final class Session {
    let document: Document
    let context: ScriptContext
    var result = ScriptResult()
    let js: JSContext

    init(document: Document, context: ScriptContext) {
        self.document = document
        self.context = context
        js = JSContext()!
    }

    func evaluate(_ source: String, name: String, timeout: Double,
                  isCancelled: @escaping @Sendable () -> Bool) throws {
        install()
        let watchdog = Watchdog(deadline: Date().addingTimeInterval(timeout), isCancelled: isCancelled)
        watchdog.arm(js)
        defer { watchdog.disarm(js) }
        js.evaluateScript(source, withSourceURL: URL(string: "file:///" + name))
        if let e = js.exception {
            js.exception = nil
            if watchdog.fired {
                throw ScriptError(message: watchdog.cancelled ? L("Cancelled") : L("Time limit of %ld s exceeded", Int(timeout)),
                                  line: nil, isTimeout: !watchdog.cancelled)
            }
            let line = e.objectForKeyedSubscript("line")?.toNumber()?.intValue
            throw ScriptError(message: e.toString() ?? L("Error"), line: line == 0 ? nil : line)
        }
    }

    // MARK: Bridge

    private func install() {
        let hw = JSValue(newObjectIn: js)!
        func fn(_ name: String, _ block: Any) { hw.setObject(block, forKeyedSubscript: name as NSString) }

        let print: @convention(block) () -> Void = { [unowned self] in
            let args = JSContext.currentArguments() as? [JSValue] ?? []
            self.result.output.append(args.map { $0.toString() ?? "" }.joined(separator: " "))
        }
        js.setObject(print, forKeyedSubscript: "print" as NSString)
        js.evaluateScript("var console = { log: print, error: print, warn: print };")

        fn("size", { [unowned self] in Double(self.document.count) } as @convention(block) () -> Double)
        fn("read", { [unowned self] (off: JSValue, len: JSValue) -> JSValue? in
            guard let r = self.range(off, len) else { return nil }
            return self.typedArray(self.document.read(r))
        } as @convention(block) (JSValue, JSValue) -> JSValue?)
        fn("write", { [unowned self] (off: JSValue, bytes: JSValue) in
            self.edit { guard let o = self.offset(off), let b = self.bytes(bytes) else { return }
                try self.document.overwrite(at: o, with: b) }
        } as @convention(block) (JSValue, JSValue) -> Void)
        fn("insert", { [unowned self] (off: JSValue, bytes: JSValue) in
            self.edit { guard let o = self.offset(off), let b = self.bytes(bytes) else { return }
                try self.document.insert(b, at: o) }
        } as @convention(block) (JSValue, JSValue) -> Void)
        fn("remove", { [unowned self] (off: JSValue, len: JSValue) in
            self.edit { guard let r = self.range(off, len) else { return }
                try self.document.delete(r) }
        } as @convention(block) (JSValue, JSValue) -> Void)

        for (name, size, signed) in [("u8", 1, false), ("u16", 2, false), ("u32", 4, false), ("u64", 8, false),
                                     ("i8", 1, true), ("i16", 2, true), ("i32", 4, true), ("i64", 8, true)] {
            fn(name, { [unowned self] (off: JSValue, le: JSValue) -> JSValue? in
                guard let raw = self.integer(off, size, le) else { return nil }
                return self.number(raw, size: size, signed: signed)
            } as @convention(block) (JSValue, JSValue) -> JSValue?)
        }
        fn("f32", { [unowned self] (off: JSValue, le: JSValue) -> JSValue? in
            guard let raw = self.integer(off, 4, le) else { return nil }
            return JSValue(double: Double(Float(bitPattern: UInt32(raw))), in: self.js)
        } as @convention(block) (JSValue, JSValue) -> JSValue?)
        fn("f64", { [unowned self] (off: JSValue, le: JSValue) -> JSValue? in
            guard let raw = self.integer(off, 8, le) else { return nil }
            return JSValue(double: Double(bitPattern: raw), in: self.js)
        } as @convention(block) (JSValue, JSValue) -> JSValue?)
        fn("str", { [unowned self] (off: JSValue, len: JSValue) -> String? in
            guard let r = self.range(off, len) else { return nil }
            return String(decoding: self.document.read(r), as: UTF8.self)
        } as @convention(block) (JSValue, JSValue) -> String?)
        fn("hex", { [unowned self] (off: JSValue, len: JSValue) -> String? in
            guard let r = self.range(off, len) else { return nil }
            return self.document.read(r).map { String(format: "%02X", $0) }.joined(separator: " ")
        } as @convention(block) (JSValue, JSValue) -> String?)
        fn("find", { [unowned self] (pattern: String, start: JSValue, end: JSValue) -> [Double]? in
            guard let p = SearchPattern.hex(pattern) else { self.fail(L("invalid hex pattern: %@", pattern)); return nil }
            return self.find(p, start, end)
        } as @convention(block) (String, JSValue, JSValue) -> [Double]?)
        fn("findText", { [unowned self] (text: String, start: JSValue, end: JSValue) -> [Double]? in
            guard let p = SearchPattern.text(text, encoding: .utf8) else { return [] }
            return self.find(p, start, end)
        } as @convention(block) (String, JSValue, JSValue) -> [Double]?)
        fn("select", { [unowned self] (start: JSValue, end: JSValue) in
            guard let s = self.offset(start), let e = self.offset(end), s <= e else { return }
            self.result.select = s ..< e
        } as @convention(block) (JSValue, JSValue) -> Void)
        fn("goto", { [unowned self] (off: JSValue) in
            if let o = self.offset(off) { self.result.goTo = o }
        } as @convention(block) (JSValue) -> Void)

        hw.setObject(Double(context.cursor), forKeyedSubscript: "cursor" as NSString)
        hw.setObject(context.selection.map { ["start": Double($0.lowerBound), "end": Double($0.upperBound)] } ?? NSNull(),
                     forKeyedSubscript: "selection" as NSString)
        hw.setObject(context.fileName, forKeyedSubscript: "fileName" as NSString)
        js.setObject(hw, forKeyedSubscript: "hw" as NSString)
    }

    // MARK: Argument helpers (throw JS exceptions on bad input)

    private func fail(_ message: String) {
        js.exception = JSValue(newErrorFromMessage: message, in: js)
    }

    private func offset(_ v: JSValue) -> UInt64? {
        let d = v.isBigInt ? Double(v.toString() ?? "") ?? -1 : v.toDouble()
        guard v.isNumber || v.isBigInt, d >= 0, d <= Double(document.count), d == d.rounded() else {
            fail(L("invalid offset: %@ (size %@)", v.toString() ?? "?", "\(document.count)"))
            return nil
        }
        return UInt64(d)
    }

    private func range(_ off: JSValue, _ len: JSValue) -> Range<UInt64>? {
        guard let o = offset(off) else { return nil }
        let l = len.toDouble()
        guard len.isNumber, l >= 0, l == l.rounded() else { fail(L("invalid length")); return nil }
        // Clamp in Double first: UInt64(1e20) or UInt64(Infinity) would trap,
        // and o + len could overflow. o <= count is guaranteed by offset().
        return o ..< o + UInt64(min(l, Double(document.count - o)))
    }

    /// Accepts Uint8Array, an array of numbers 0…255, or a string (UTF-8).
    private func bytes(_ v: JSValue) -> Data? {
        let ctx = js.jsGlobalContextRef
        if JSValueGetTypedArrayType(ctx, v.jsValueRef, nil) != kJSTypedArrayTypeNone,
           let obj = JSValueToObject(ctx, v.jsValueRef, nil) {
            let n = JSObjectGetTypedArrayByteLength(ctx, obj, nil)
            let off = JSObjectGetTypedArrayByteOffset(ctx, obj, nil)
            guard let p = JSObjectGetTypedArrayBytesPtr(ctx, obj, nil) else { return Data() }
            return Data(bytes: p.advanced(by: off), count: n)
        }
        if v.isString { return Data((v.toString() ?? "").utf8) }
        if v.isArray, let a = v.toArray() {
            var out = Data(capacity: a.count)
            for x in a {
                guard let n = x as? NSNumber, (0...255).contains(n.intValue), n.doubleValue == Double(n.intValue) else {
                    fail(L("Byte array may only contain numbers 0–255")); return nil
                }
                out.append(UInt8(n.intValue))
            }
            return out
        }
        fail(L("Bytes expected (Array, Uint8Array or String)"))
        return nil
    }

    private func edit(_ body: () throws -> Void) {
        do {
            try body()
            result.edits += 1
        } catch {
            fail(String(describing: error))
        }
    }

    private func integer(_ off: JSValue, _ size: Int, _ le: JSValue) -> UInt64? {
        guard let o = offset(off) else { return nil }
        let d = document.read(o ..< o + UInt64(size))
        guard d.count == size else { fail(L("Read past the end of the file at %@", "\(o)")); return nil }
        let little = le.isUndefined || le.toBool()
        var v: UInt64 = 0
        for b in (little ? d.reversed() : Array(d)) { v = v << 8 | UInt64(b) }
        return v
    }

    private func number(_ raw: UInt64, size: Int, signed: Bool) -> JSValue {
        if signed {
            let shift = UInt64(64 - size * 8)
            let s = Int64(bitPattern: raw << shift) >> Int64(shift)
            return size == 8 ? bigInt(String(s)) : JSValue(double: Double(s), in: js)
        }
        return size == 8 ? bigInt(String(raw)) : JSValue(double: Double(raw), in: js)
    }

    private func bigInt(_ decimal: String) -> JSValue {
        js.evaluateScript("BigInt(\"\(decimal)\")")
    }

    private func typedArray(_ data: Data) -> JSValue? {
        let ctx = js.jsGlobalContextRef
        guard let obj = JSObjectMakeTypedArray(ctx, kJSTypedArrayTypeUint8Array, data.count, nil) else { return nil }
        if let p = JSObjectGetTypedArrayBytesPtr(ctx, obj, nil), !data.isEmpty {
            data.copyBytes(to: p.assumingMemoryBound(to: UInt8.self), count: data.count)
        }
        return JSValue(jsValueRef: obj, in: js)
    }

    private func find(_ p: SearchPattern, _ start: JSValue, _ end: JSValue) -> [Double]? {
        let s = start.isUndefined ? 0 : offset(start)
        let e = end.isUndefined ? document.count : offset(end)
        guard let s, let e else { return nil }
        return Search.find(p, in: document.snapshot(), range: s ..< max(s, e)).map { Double($0.lowerBound) }
    }
}

/// Stops runaway scripts: JavaScriptCore's execution time limit is exported
/// but not in the public headers, so it is looked up at runtime. Without it
/// scripts simply have no time limit.
private final class Watchdog {
    typealias ShouldTerminate = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Bool
    typealias SetLimit = @convention(c) (JSContextGroupRef?, Double, ShouldTerminate?, UnsafeMutableRawPointer?) -> Void
    typealias ClearLimit = @convention(c) (JSContextGroupRef?) -> Void

    let deadline: Date
    let isCancelled: @Sendable () -> Bool
    private(set) var fired = false
    private(set) var cancelled = false

    init(deadline: Date, isCancelled: @escaping @Sendable () -> Bool) {
        self.deadline = deadline
        self.isCancelled = isCancelled
    }

    nonisolated(unsafe) private static let handle = dlopen(nil, RTLD_NOW)
    private var group: JSContextGroupRef?
    private var set: SetLimit?

    /// JavaScriptCore calls this once when the limit is reached; returning
    /// false continues but does not re-arm, so it re-arms itself.
    private static let callback: ShouldTerminate = { _, ctx in
        guard let ctx else { return false }
        let w = Unmanaged<Watchdog>.fromOpaque(ctx).takeUnretainedValue()
        if w.isCancelled() { w.cancelled = true; w.fired = true; return true }
        if Date() >= w.deadline { w.fired = true; return true }
        w.set?(w.group, 0.2, Watchdog.callback, ctx)
        return false
    }

    func arm(_ js: JSContext) {
        guard let sym = dlsym(Self.handle, "JSContextGroupSetExecutionTimeLimit") else { return }
        set = unsafeBitCast(sym, to: SetLimit.self)
        group = JSContextGetGroup(js.jsGlobalContextRef)
        // Checked every 0.2 s of script time (cancel button, deadline).
        set?(group, 0.2, Self.callback, Unmanaged.passUnretained(self).toOpaque())
    }

    func disarm(_ js: JSContext) {
        guard let sym = dlsym(Self.handle, "JSContextGroupClearExecutionTimeLimit") else { return }
        unsafeBitCast(sym, to: ClearLimit.self)(JSContextGetGroup(js.jsGlobalContextRef))
    }
}
