import AppKit
import Combine
import HexwerkCore
import SwiftUI

/// Programmer's calculator in a floating panel.
@MainActor
final class CalculatorModel: ObservableObject {
    @Published var expression = "" { didSet { evaluate() } }
    @Published var bits = 64 { didSet { evaluate() } }
    @Published private(set) var views: Calculator.Views?
    @Published private(set) var error: String?
    @Published private(set) var value: UInt64?
    private var ans: UInt64 = 0

    /// Variables of the frontmost document (cursor, selection, bytes).
    var context: () -> [String: UInt64] = { [:] }
    var goTo: (UInt64) -> Void = { _ in }

    func evaluate() {
        let t = expression.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { views = nil; error = nil; value = nil; return }
        var vars = context()
        vars["ans"] = ans
        do {
            let v = try Calculator.evaluate(t, variables: vars)
            value = v
            views = Calculator.Views(v, bits: bits)
            error = nil
        } catch {
            self.error = String(describing: error)
        }
    }

    /// Return: keep the result as `ans` for the next expression.
    func commit() {
        if let value { ans = value }
    }
}

struct CalculatorView: View {
    @ObservedObject var calc: CalculatorModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(L("e.g. pos + 0x40, u32 >> 4, 'MZ'"), text: $calc.expression)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14, design: .monospaced))
                .focused($focused)
                .onSubmit { calc.commit() }
            Picker("", selection: $calc.bits) {
                ForEach([8, 16, 32, 64], id: \.self) { Text(L("%ld bit", $0)).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()

            if let e = calc.error {
                Text(e).foregroundStyle(.red).font(.callout)
            }
            if let v = calc.views {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                    row("Hex", v.hex)
                    row(L("Decimal"), v.unsigned)
                    row(L("Signed"), v.signed)
                    row(L("Octal"), v.octal)
                    row(L("Binary"), v.binary)
                    row("ASCII", v.ascii)
                    if calc.bits == 32 { row("Float32", v.float32) }
                    if calc.bits == 64 { row("Float64", v.float64) }
                }
                HStack {
                    Spacer()
                    Button(L("Go to Result")) { if let x = calc.value { calc.goTo(x) } }
                        .help(L("Move the cursor in the front document to this offset or address"))
                }
            }
            Divider()
            Text(L("Variables: pos, sel, size, u8, u16, u32, u64 (value under the cursor), ans. Operators: + − * / % ** << >> & | ^ ~"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 400)
        .onAppear { focused = true }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                .lineLimit(1).truncationMode(.middle)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            } label: { Image(systemName: "doc.on.doc") }
            .buttonStyle(.borderless)
            .help(L("Copy"))
        }
    }
}

@MainActor
final class CalculatorPanel {
    static let shared = CalculatorPanel()
    let model = CalculatorModel()
    private var panel: NSPanel?

    func toggle() {
        if let panel, panel.isVisible { panel.orderOut(nil); return }
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 360),
                            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.title = L("Calculator")
            p.isFloatingPanel = true
            p.becomesKeyOnlyIfNeeded = false
            p.hidesOnDeactivate = true
            p.contentViewController = NSHostingController(rootView: CalculatorView(calc: model))
            p.setFrameAutosaveName("hexwerk.calculator")
            if !p.setFrameUsingName("hexwerk.calculator") { p.center() }
            panel = p
        }
        model.evaluate()
        panel?.makeKeyAndOrderFront(nil)
    }
}
