import AppKit
import HexwerkCore
import HexwerkYARA
import SwiftUI

/// YARA-X rules and scan results.
struct YaraTab: View {
    @ObservedObject var model: DocumentModel
    @ObservedObject var yara: YaraModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
    }

    // MARK: Rules, scope, scan button, messages

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("Rules")).font(.headline)
                Spacer()
                Button {
                    addRules()
                } label: {
                    Label(L("Add"), systemImage: "plus")
                }
                .controlSize(.small)
            }
            if yara.ruleFiles.isEmpty {
                Text(L("Add rule files (.yar) or folders.")).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(yara.ruleFiles, id: \.self) { url in
                HStack(spacing: 6) {
                    Image(systemName: isFolder(url) ? "folder" : "doc.text").foregroundStyle(.secondary)
                    Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button {
                        yara.removeRules(url)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
                    .help(L("Remove from the list"))
                }
                .font(.callout)
                .help(url.path)
            }

            HStack {
                Picker("", selection: $yara.scope) {
                    ForEach(YaraModel.Scope.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .disabled(model.selection == nil)
                .help(L("Scan the whole file or only the selection"))
                Spacer()
                Stepper(L("Time limit %ld s", yara.timeout), value: $yara.timeout, in: 5 ... 600, step: 5)
                    .font(.caption).monospacedDigit().fixedSize()
                    .help(L("Time limit of the scan"))
            }
            HStack {
                if yara.running {
                    ProgressView().controlSize(.small)
                    Text(L("Scanning…")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Cancel")) { yara.cancel() }
                } else {
                    Button {
                        scan()
                    } label: {
                        Label(L("Scan"), systemImage: "shield.lefthalf.filled").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(yara.ruleFiles.isEmpty)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .help(L("Scan with all rules (⌘↩, in the menu ⇧⌘Y)"))
                }
            }
            .onChange(of: model.selection == nil) { _, none in if none { yara.scope = .file } }

            if yara.stale {
                banner(
                    L("Content changed – hits may have shifted"), "arrow.clockwise", .orange,
                    action: (L("Scan Again"), scan))
            }
            ForEach(Array(yara.compileErrors.enumerated()), id: \.offset) { _, d in
                banner(d.description, "exclamationmark.triangle.fill", .red, action: nil)
                    .help(d.report)
            }
            if let e = yara.scanError {
                banner(e, "exclamationmark.triangle.fill", .red, action: nil)
            }
            if !yara.warnings.isEmpty {
                DisclosureGroup(yara.warnings.count == 1 ? L("1 warning") : L("%ld warnings", yara.warnings.count)) {
                    ForEach(Array(yara.warnings.enumerated()), id: \.offset) { _, w in
                        Text(w.description).font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).help(w.report)
                    }
                }
                .font(.caption)
            }
            if case let summary = yara.summary({ model.addressText($0) }), !summary.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if yara.matchCount > 0 {
                        Button(L("Bookmark All")) {
                            model.bookmarkAll(
                                (yara.results ?? []).flatMap { r in r.matches.map { ("\(r.rule) \($0.pattern)", $0.range) } })
                        }
                        .buttonStyle(.link).font(.caption)
                        .help(L("Add a bookmark for every hit"))
                    }
                }
            }
        }
        .padding(10)
    }

    // MARK: Results

    @ViewBuilder private var content: some View {
        if let results = yara.results {
            if results.isEmpty {
                placeholder("checkmark.shield", L("No rule matched."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(results) { r in ruleRows(r) }
                    }
                    .padding(.vertical, 4)
                }
            }
        } else if !yara.running {
            placeholder("shield.lefthalf.filled", L("No scan yet.\nAdd rules and click “Scan” (⌘↩)."))
        } else {
            Spacer()
        }
    }

    @ViewBuilder private func ruleRows(_ r: YaraRuleMatch) -> some View {
        let open = yara.expanded.contains(r.id)
        HStack(spacing: 6) {
            Image(systemName: open ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold)).frame(width: 14).foregroundStyle(.secondary)
            Text(r.rule).fontWeight(.medium).lineLimit(1)
            if r.namespace != "default" { Text(r.namespace).foregroundStyle(.tertiary).lineLimit(1) }
            ForEach(r.tags, id: \.self) { t in
                Text(t).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.pink.opacity(0.18), in: Capsule())
            }
            Spacer(minLength: 6)
            Text(r.matches.isEmpty ? L("condition") : "\(r.matches.count)")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10).frame(height: 24)
        .rowButton {
            if open { yara.expanded.remove(r.id) } else { yara.expanded.insert(r.id) }
        }
        .accessibilityValue(open ? L("expanded") : L("collapsed"))
        if open {
            ForEach(r.metadata, id: \.self) { m in
                HStack(alignment: .firstTextBaseline) {
                    Text(m.key).foregroundStyle(.secondary)
                    Text(m.value).textSelection(.enabled).lineLimit(2)
                }
                .font(.caption).padding(.leading, 30).padding(.trailing, 10).padding(.vertical, 1)
            }
            // Long lists are capped in the view; markings show all matches.
            ForEach(r.matches.prefix(2000), id: \.self) { m in matchRow(m) }
            if r.matches.count > 2000 {
                Text(L("… %ld more (marked in the grid)", r.matches.count - 2000))
                    .font(.caption).foregroundStyle(.tertiary).padding(.leading, 30)
            }
        }
    }

    private func matchRow(_ m: YaraPatternMatch) -> some View {
        let selected = yara.selectedMatch == m
        return HStack(spacing: 8) {
            Text(model.addressText(m.offset)).monospaced()
            Text(m.pattern).foregroundStyle(.pink)
            if let k = m.xorKey { Text("xor \(String(format: "0x%02X", k))").font(.caption2).foregroundStyle(.secondary) }
            Spacer(minLength: 6)
            Text(preview(m)).monospaced().foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
        }
        .font(.system(size: 11))
        .padding(.leading, 30).padding(.trailing, 10).frame(height: 20)
        .background(selected ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 4))
        .padding(.horizontal, 4)
        .rowButton(selected: selected) {
            yara.selectedMatch = m
            model.jump?(m.offset, m.length > 0 ? m.range : nil)
        }
        .help(L("%llu bytes", m.length))
    }

    private func preview(_ m: YaraPatternMatch) -> String {
        let bytes = model.doc.read(m.offset ..< m.offset + min(m.length, 24))
        let printable = bytes.allSatisfy { (0x20 ..< 0x7F).contains($0) }
        return printable
            ? String(decoding: bytes, as: UTF8.self)
            : bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    // MARK: Helpers

    private func scan() { yara.scan(model.doc.snapshot(), selection: model.selection) }

    private func addRules() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = L("Choose YARA rule files or folders")
        try? FileManager.default.createDirectory(at: YaraModel.rulesDir, withIntermediateDirectories: true)
        panel.directoryURL = YaraModel.rulesDir
        guard panel.runModal() == .OK else { return }
        yara.addRules(panel.urls)
    }

    private func isFolder(_ url: URL) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
    }

    private func placeholder(_ symbol: String, _ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(.tertiary)
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func banner(_ text: String, _ symbol: String, _ tint: Color, action: (String, () -> Void)?) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: 0)
            if let action { Button(action.0, action: action.1).controlSize(.small) }
        }
        .padding(8)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }
}
