import AppKit
import HexwerkCore
import SwiftUI

func hex(_ v: UInt64) -> String { "0x" + String(v, radix: 16, uppercase: true) }

// MARK: - Sidebar (inspector)

struct Sidebar: View {
    @ObservedObject var model: DocumentModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $model.sidebarTab) {
                ForEach(DocumentModel.SidebarTab.allCases, id: \.self) { tab in
                    Image(systemName: tab.symbol).help(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)

            Divider()
            switch model.sidebarTab {
            case .data: DataTab(model: model)
            case .structure: StructureTab(model: model, structure: model.structure)
            case .yara: YaraTab(model: model, yara: model.yara)
            case .analysis: AnalysisTab(model: model, analysis: model.analysis)
            case .script: ScriptTab(model: model, script: model.script)
            case .strings: StringsTab(model: model, strings: model.strings)
            case .image: ImageTab(model: model, image: model.image)
            case .hits: HitsTab(model: model)
            case .bookmarks: BookmarksTab(model: model)
            case .checksums: ChecksumsTab(model: model)
            }
        }
        .frame(minWidth: 280)
    }
}

/// Edit field for one inspector row: Return writes, Esc cancels.
struct InspectorEditField: View {
    @ObservedObject var model: DocumentModel
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $model.inspectorText)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11.5, design: .monospaced))
            .focused($focused)
            .onSubmit { model.commitInspectorEdit() }
            .onExitCommand { model.cancelInspectorEdit() }
            .onAppear { focused = true }
            .frame(minWidth: 140)
    }
}

/// Data inspector, grouped like the Finder info panel.
struct DataTab: View {
    @ObservedObject var model: DocumentModel

    private let groups: [(String, [String])] = [
        ("Ganzzahlen", ["int8", "uint8", "int16", "uint16", "int32", "uint32", "int64", "uint64"]),
        ("Gleitkomma", ["float32", "float64"]),
        ("Zeit", ["Unix-Zeit 32", "Unix-Zeit 64", "FILETIME", "DOS-Datum/Zeit"]),
        ("Sonstiges", ["binär", "GUID", "ULEB128", "SLEB128"]),
        ("Text", ["ASCII", "UTF-8", "UTF-16 LE", "UTF-16 BE"]),
    ]

    var body: some View {
        let values = Dictionary(model.inspectorValues.map { ($0.name, $0.value) }, uniquingKeysWith: { a, _ in a })
        Form {
            Section {
                Picker("Endian", selection: $model.endian) {
                    Text("Little Endian").tag(Endian.little)
                    Text("Big Endian").tag(Endian.big)
                }
                LabeledContent("Offset") {
                    Text("\(hex(model.cursor))  ·  \(model.cursor)")
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            ForEach(groups, id: \.0) { title, names in
                Section(title) {
                    ForEach(names, id: \.self) { name in
                        LabeledContent(name) {
                            if model.inspectorEditing == name {
                                InspectorEditField(model: model)
                            } else {
                                Text((values[name] ?? nil) ?? "—")
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundStyle((values[name] ?? nil) == nil ? .tertiary : .primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) { model.beginInspectorEdit(name, current: values[name] ?? nil) }
                                    .help(model.doc.isReadOnly ? "" : "Doppelklick zum Bearbeiten")
                            }
                        }
                        if model.inspectorEditing == name, let e = model.inspectorError {
                            Text(e).font(.caption).foregroundStyle(.red)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .font(.system(size: 12))
        .controlSize(.small)
    }
}

struct HitsTab: View {
    @ObservedObject var model: DocumentModel

    static func describe(_ d: DiffOp) -> String {
        switch d.kind {
        case .replace: d.a.count == d.b.count ? "\(d.a.count) B geändert" : "\(d.a.count) → \(d.b.count) B"
        case .insert: "+\(d.b.count) B nur dort"
        case .delete: "−\(d.a.count) B nur hier"
        }
    }

    var body: some View {
        List {
            if let file = model.diffFile {
                Section {
                    ForEach(Array(model.diffs.prefix(5000).enumerated()), id: \.offset) { _, d in
                        Button { model.show(diff: d) } label: {
                            HStack(spacing: 6) {
                                Circle().fill(Color(nsColor: model.diffHighlight(d).1.withAlphaComponent(1))).frame(width: 7, height: 7)
                                Text(hex(d.a.lowerBound)).monospaced()
                                Text("↔ \(hex(d.b.lowerBound))").monospaced().foregroundStyle(.secondary)
                                Spacer()
                                Text(Self.describe(d)).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    HStack {
                        Text("Unterschiede zu \(file.lastPathComponent): \(model.diffs.count)")
                        Spacer()
                        Button("Schließen") { model.clearDiff() }.buttonStyle(.link)
                    }
                }
            }
            Section(model.hits.isEmpty ? "Suchtreffer" : "Suchtreffer: \(model.hits.count)") {
                if model.hits.isEmpty {
                    Text("Suche mit ⌘F").foregroundStyle(.secondary)
                }
                // Long lists are capped; navigation via ⌘G still reaches all hits.
                ForEach(Array(model.hits.prefix(5000).enumerated()), id: \.offset) { i, r in
                    Button { model.select(hit: i) } label: {
                        HStack {
                            Text(hex(r.lowerBound)).monospaced()
                            Spacer()
                            Text(preview(r)).monospaced().foregroundStyle(.secondary).lineLimit(1)
                        }
                        .padding(.vertical, 1)
                        .background(model.currentHit == i ? Color.accentColor.opacity(0.18) : .clear,
                                    in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .font(.system(size: 11.5))
    }

    private func preview(_ r: Range<UInt64>) -> String {
        model.doc.read(r.lowerBound ..< min(r.upperBound, r.lowerBound + 8)).map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

struct BookmarksTab: View {
    @ObservedObject var model: DocumentModel

    var body: some View {
        List {
            if model.bookmarks.isEmpty {
                Text("Lesezeichen mit ⌘D setzen").foregroundStyle(.secondary)
            }
            ForEach($model.bookmarks) { $b in
                HStack(spacing: 8) {
                    Circle().fill(Color(nsColor: b.color)).frame(width: 9, height: 9)
                    TextField("Name", text: $b.name).textFieldStyle(.plain)
                    Spacer()
                    Button(hex(b.range.lowerBound)) { model.jump?(b.range.lowerBound, b.range) }
                        .buttonStyle(.link).monospaced()
                    Text("\(b.range.count) B").foregroundStyle(.secondary)
                    Button {
                        model.bookmarks.removeAll { $0.id == b.id }
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
        }
        .font(.system(size: 11.5))
    }
}

struct ChecksumsTab: View {
    @ObservedObject var model: DocumentModel

    var body: some View {
        Form {
            Section {
                HStack {
                    Button(model.selection == nil ? "Für ganze Datei berechnen" : "Für Auswahl berechnen") {
                        model.computeChecksums()
                    }
                    .disabled(model.checksumRunning || model.checksumSelection.isEmpty)
                    if model.checksumRunning { ProgressView().controlSize(.small) }
                    Spacer()
                    Menu("Auswahl") {
                        Button("Gängige (CRC32, MD5, SHA-1, SHA-256)") { model.checksumSelection = Set(Checksum.common) }
                        Button("Alle") { model.checksumSelection = Set(Checksum.allCases) }
                        ForEach(Checksum.Group.allCases, id: \.self) { g in
                            Button("Alle \(g.rawValue)") {
                                model.checksumSelection.formUnion(Checksum.allCases.filter { $0.group == g })
                            }
                        }
                        Button("Keine") { model.checksumSelection = [] }
                    }
                    .fixedSize()
                }
                if !model.checksumScope.isEmpty {
                    Text(model.checksumScope).foregroundStyle(.secondary)
                }
            }
            ForEach(Checksum.Group.allCases, id: \.self) { g in
                Section(g.rawValue) {
                    ForEach(Checksum.allCases.filter { $0.group == g }, id: \.self) { c in row(c) }
                }
            }
        }
        .formStyle(.grouped)
        .font(.system(size: 11.5))
    }

    private func row(_ c: Checksum) -> some View {
        HStack(spacing: 6) {
            Toggle(isOn: Binding(get: { model.checksumSelection.contains(c) },
                                 set: { on in if on { model.checksumSelection.insert(c) } else { model.checksumSelection.remove(c) } })) {
                Text(c.rawValue)
            }
            .toggleStyle(.checkbox)
            .fixedSize()
            Spacer(minLength: 4)
            if let v = model.checksums[c] {
                Text(v).monospaced().textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(v, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help("Kopieren")
            }
        }
    }
}

// MARK: - Find bar

struct FindBar: View {
    @ObservedObject var model: DocumentModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Picker("", selection: $model.findMode) {
                    ForEach(DocumentModel.FindMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 90)

                if model.findMode == .regex {
                    Toggle("Aa", isOn: $model.ignoreCase.not)
                        .toggleStyle(.button)
                        .help("Groß-/Kleinschreibung beachten")
                }
                if model.findMode == .text {
                    Picker("", selection: $model.textEncoding) {
                        Text("UTF-8").tag(SearchPattern.TextEncoding.utf8)
                        Text("ASCII").tag(SearchPattern.TextEncoding.ascii)
                        Text("UTF-16 LE").tag(SearchPattern.TextEncoding.utf16le)
                        Text("UTF-16 BE").tag(SearchPattern.TextEncoding.utf16be)
                    }
                    .labelsHidden()
                    .frame(width: 100)
                    Toggle("Aa", isOn: $model.ignoreCase.not)
                        .toggleStyle(.button)
                        .help("Groß-/Kleinschreibung beachten")
                }

                TextField(placeholder, text: $model.findText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($focused)
                    .onSubmit { model.runSearch() }

                if model.searching {
                    ProgressView(value: model.progress).frame(width: 60)
                    Button("Stopp") { model.cancelSearch() }
                } else if let msg = model.findMessage {
                    Text(msg).foregroundStyle(.secondary).font(.callout)
                } else if !model.hits.isEmpty {
                    Text("\((model.currentHit ?? 0) + 1) von \(model.hits.count)")
                        .foregroundStyle(.secondary).font(.callout).monospacedDigit()
                }

                ControlGroup {
                    Button { model.previousHit() } label: { Image(systemName: "chevron.left") }
                    Button { model.nextHit() } label: { Image(systemName: "chevron.right") }
                }
                .frame(width: 60)
                .disabled(model.findText.isEmpty)

                Toggle(isOn: $model.showReplace) { Image(systemName: "arrow.2.squarepath") }
                    .toggleStyle(.button)
                    .help("Ersetzen")

                Button { model.findVisible = false } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
            }
            if model.showReplace {
                HStack(spacing: 8) {
                    Text("Ersetzen durch").foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
                    TextField(placeholder, text: $model.replaceText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    Button("Ersetzen") { model.replaceCurrent() }.disabled(model.currentHit == nil || model.doc.isReadOnly)
                    Button("Alle") { model.replaceAll() }.disabled(model.hits.isEmpty || model.doc.isReadOnly)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .onAppear { focused = true }
    }

    private var placeholder: String {
        switch model.findMode {
        case .hex: "Hex, z. B. 4D 5A ?? 00"
        case .text: "Text"
        case .regex: "Regex über Bytes, z. B. \\x7fELF|[a-z]+@[a-z.]+"
        default: "Zahl"
        }
    }
}

extension Binding where Value == Bool {
    /// The inverse of a boolean binding ("Aa" shows "case matters").
    var not: Binding<Bool> { Binding(get: { !wrappedValue }, set: { wrappedValue = !$0 }) }
}

// MARK: - Status bar

struct StatusBar: View {
    @ObservedObject var model: DocumentModel
    @ObservedObject var structure: StructureModel
    @ObservedObject var yara: YaraModel
    @ObservedObject var analysis: AnalysisModel

    var body: some View {
        HStack(spacing: 0) {
            // Offset: click opens "go to".
            Button { send(#selector(DocumentWindowController.goToOffset(_:))) } label: {
                field("Offset", "\(hex(model.cursor)) (\(model.cursor))")
            }
            .help("Gehe zu Offset (⌘L)")
            if model.offsetBase != 0 {
                sep
                field("Adresse", hex(model.cursor + model.offsetBase))
            }
            if let s = model.selection, !s.isEmpty {
                sep
                field("Auswahl", "\(hex(s.lowerBound))–\(hex(s.upperBound - 1)) (\(s.count) Byte)")
            }
            if let b = byteAtCursor {
                sep
                field("Wert", "\(b) · 0x\(String(format: "%02X", b)) · \(String(b, radix: 2).leftPad(8))")
                    .help("Byte unter dem Cursor: dezimal, hex, binär")
            }
            Spacer(minLength: 12)

            if model.vimEnabled {
                Text("-- \(model.vimStatus) --").fontWeight(.semibold)
                    .foregroundStyle(model.vim.mode == .normal ? Color.secondary : Color.accentColor)
                sep
            }
            if let t = analysis.typeDescription {
                Button { send(#selector(DocumentWindowController.showAnalysis(_:))) } label: {
                    Text(t.split(separator: ",").first.map(String.init) ?? t).lineLimit(1).truncationMode(.tail)
                        .foregroundStyle(.secondary)
                }
                .help(t)
                .frame(maxWidth: 220)
                sep
            }
            if structure.parsing || structure.result != nil || structure.formatTitle != nil {
                Button { send(#selector(DocumentWindowController.showStructure(_:))) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: structure.result?.error != nil || structure.loadError != nil
                              ? "exclamationmark.triangle.fill" : "list.bullet.indent")
                            .foregroundStyle(structure.result?.error != nil || structure.loadError != nil ? .orange : .secondary)
                        Text(structure.formatTitle ?? "Format")
                    }
                }
                .help("Struktur anzeigen")
                sep
            }
            if let r = yara.results {
                Button { send(#selector(DocumentWindowController.showYara(_:))) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "shield.lefthalf.filled").foregroundStyle(r.isEmpty ? Color.secondary : Color.pink)
                        Text(r.isEmpty ? "YARA: nichts" : "YARA: \(r.count) \(r.count == 1 ? "Regel" : "Regeln")")
                    }
                }
                .help(yara.summary)
                sep
            }
            Menu {
                Picker("Zeichensatz", selection: $model.charset) {
                    ForEach(TextEncodingView.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
            } label: { Text(model.charset.rawValue) }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Zeichensatz der Textspalte")
            sep
            Menu {
                Picker("Byte-Reihenfolge", selection: $model.endian) {
                    Text("Little Endian").tag(Endian.little)
                    Text("Big Endian").tag(Endian.big)
                }
                .pickerStyle(.inline)
            } label: { Text(model.endian == .little ? "LE" : "BE") }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Byte-Reihenfolge für Inspektor und Zahlensuche")
            sep
            if model.doc.isReadOnly {
                Label("Schreibgeschützt", systemImage: "lock.fill").foregroundStyle(.secondary)
            } else {
                Button { model.insertMode.toggle() } label: {
                    Text(model.insertMode ? "EIN" : "ÜBS").fontWeight(.medium)
                }
                .help(model.insertMode ? "Einfügemodus – klicken für Überschreiben (⌘I)"
                                       : "Überschreibmodus – klicken für Einfügen (⌘I)")
            }
            sep
            Text(ByteCountFormatter.string(fromByteCount: Int64(model.doc.count), countStyle: .binary))
                .help("\(model.doc.count) Byte")
            if model.doc.isModified {
                Circle().fill(Color.orange).frame(width: 7, height: 7).padding(.leading, 8)
                    .help("Ungesicherte Änderungen")
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 11))
        .monospacedDigit()
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(height: 26)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        // Re-render on content changes (size, modified), not only cursor moves.
        .id(model.revision)
    }

    private var byteAtCursor: UInt8? {
        model.cursor < model.doc.count ? model.doc.read(model.cursor ..< model.cursor + 1).first : nil
    }

    private var sep: some View {
        Divider().frame(height: 12).padding(.horizontal, 10)
    }

    private func field(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
        .contentShape(Rectangle())
    }

    private func send(_ action: Selector) { NSApp.sendAction(action, to: nil, from: nil) }
}

// MARK: - Small sheets

/// Holds the prompt's text. A class instead of @State: SwiftUI's @State is a
/// macro in this SDK and its plugin is missing from the Command Line Tools.
final class PromptText: ObservableObject {
    @Published var value: String
    init(_ value: String) { self.value = value }
}

/// One text field with OK/Cancel (go to offset, fill pattern, bookmark name).
struct PromptSheet: View {
    let title: String
    let message: String
    let placeholder: String
    @ObservedObject var input: PromptText
    let validate: (String) -> Bool
    let done: (String?) -> Void

    private var text: String { input.value }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text(message).foregroundStyle(.secondary).font(.callout)
            TextField(placeholder, text: $input.value)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: .monospaced))
                .onSubmit { if validate(text) { done(text) } }
            HStack {
                Spacer()
                Button("Abbrechen") { done(nil) }.keyboardShortcut(.cancelAction)
                Button("OK") { done(text) }.keyboardShortcut(.defaultAction).disabled(!validate(text))
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
