import AppKit
import HexwerkCore
import SwiftUI

/// View → Highlight Rules…: rules of this file and of all files (#141).
struct HighlightRulesSheet: View {
    @ObservedObject var rules: HighlightRulesModel
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Highlight Rules")).font(.headline)
            Text(L("Bytes matching a rule are colored in the hex view. Hex patterns may contain ?? wildcards."))
                .foregroundStyle(.secondary).font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(L("Highlight zero bytes"), isOn: $rules.zeroBytes)
            section(L("This File"), L("Saved in the project file."), $rules.fileRules)
            section(L("All Files"), L("Saved in the settings."), $rules.globalRules)
            HStack {
                Spacer()
                Button(L("Done")) { done() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func section(_ title: String, _ note: String, _ list: Binding<[HighlightRule]>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Text(note).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    let color = list.wrappedValue.count % (HighlightRulesModel.palette.count - 1)
                    list.wrappedValue.append(HighlightRule(kind: .hex, pattern: "", color: color))
                } label: {
                    Image(systemName: "plus")
                }
                .help(L("Add Rule"))
            }
            if list.wrappedValue.isEmpty {
                Text(L("No rules")).font(.caption).foregroundStyle(.tertiary)
            }
            ForEach(list) { $rule in
                RuleRow(rule: $rule) { list.wrappedValue.removeAll { $0.id == rule.id } }
            }
        }
        .controlSize(.small)
    }
}

private struct RuleRow: View {
    @Binding var rule: HighlightRule
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Toggle("", isOn: $rule.enabled).labelsHidden()
            Menu {
                ForEach(HighlightRulesModel.palette.indices, id: \.self) { i in
                    Button {
                        rule.color = i
                    } label: {
                        Image(nsImage: Self.swatch(i))
                    }
                }
            } label: {
                Image(nsImage: Self.swatch(rule.color))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(L("Color"))
            Picker("", selection: $rule.kind) {
                Text("Hex").tag(HighlightRule.Kind.hex)
                Text("Text").tag(HighlightRule.Kind.text)
                Text("Regex").tag(HighlightRule.Kind.regex)
            }
            .labelsHidden().pickerStyle(.segmented).fixedSize()
            TextField(placeholder, text: $rule.pattern)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.red.opacity(rule.pattern.isEmpty || rule.isValid ? 0 : 0.8), lineWidth: 1)
                )
                .help(rule.pattern.isEmpty || rule.isValid ? "" : L("Invalid pattern"))
            Toggle("Aa", isOn: $rule.ignoreCase).toggleStyle(.button)
                .disabled(rule.kind == .hex)
                .help(L("Ignore case"))
            Button(action: remove) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help(L("Remove Rule"))
        }
    }

    private var placeholder: String {
        switch rule.kind {
        case .hex: "4D 5A ?? 00"
        case .text: "PK"
        case .regex: "[\\x20-\\x7e]{8,}"
        }
    }

    /// Menus show images, not SwiftUI shapes, so the swatch is drawn.
    static func swatch(_ i: Int) -> NSImage {
        let color = HighlightRulesModel.palette[i % HighlightRulesModel.palette.count]
        let img = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { r in
            color.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        return img
    }
}
