import AppKit
import HexwerkCore
import SwiftUI

func hex(_ v: UInt64) -> String { "0x" + String(v, radix: 16, uppercase: true) }

extension View {
    /// A clickable list row that is a real button, so VoiceOver and the
    /// keyboard (Space with full keyboard access) can activate it too.
    func rowButton(selected: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Sidebar (inspector)

struct Sidebar: View {
    @ObservedObject var model: DocumentModel

    var body: some View {
        VStack(spacing: 0) {
            // Icon-only segments: the Label's title is what VoiceOver reads.
            Picker(L("Sidebar"), selection: $model.sidebarTab) {
                ForEach(DocumentModel.SidebarTab.allCases, id: \.self) { tab in
                    Label(tab.title, systemImage: tab.symbol).labelStyle(.iconOnly).help(tab.title).tag(tab)
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
        (L("Integers"), ["int8", "uint8", "int16", "uint16", "int32", "uint32", "int64", "uint64"]),
        (L("Floating Point"), ["float32", "float64"]),
        (L("Time"), ["Unix time 32", "Unix time 64", "FILETIME", "DOS date/time"]),
        (L("Other"), ["binary", "GUID", "ULEB128", "SLEB128"]),
        (L("Text"), ["ASCII", "UTF-8", "UTF-16 LE", "UTF-16 BE"]),
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
                        LabeledContent(Inspector.title(of: name)) {
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
                                    .help(model.doc.isReadOnly ? "" : L("Double-click to edit"))
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
        case .replace: d.a.count == d.b.count ? L("%ld B changed", d.a.count) : "\(d.a.count) → \(d.b.count) B"
        case .insert: L("+%ld B only there", d.b.count)
        case .delete: L("−%ld B only here", d.a.count)
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
                        Text(L("Differences from %1$@: %2$ld", file.lastPathComponent, model.diffs.count)
                             + (model.diffsTruncated ? " (" + L("stopped after %ld hits", Search.maxHits) + ")" : ""))
                        Spacer()
                        Button(L("Close")) { model.clearDiff() }.buttonStyle(.link)
                    }
                }
            }
            Section(model.hits.isEmpty ? L("Search Hits") : L("Search Hits: %ld", model.hits.count)) {
                if model.hits.isEmpty {
                    Text(L("Search with ⌘F")).foregroundStyle(.secondary)
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
                Text(L("Add bookmarks with ⌘D")).foregroundStyle(.secondary)
            }
            ForEach($model.bookmarks) { $b in
                HStack(spacing: 8) {
                    Circle().fill(Color(nsColor: b.color)).frame(width: 9, height: 9)
                    TextField(L("Name"), text: $b.name).textFieldStyle(.plain)
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
                    Button(model.selection == nil ? L("Compute for Whole File") : L("Compute for Selection")) {
                        model.computeChecksums()
                    }
                    .disabled(model.checksumRunning || model.checksumSelection.isEmpty)
                    if model.checksumRunning {
                        ProgressView().controlSize(.small)
                        Button(L("Cancel")) { model.cancelChecksums() }.controlSize(.small)
                    }
                    Spacer()
                    Menu(L("Choose")) {
                        Button(L("Common (CRC32, MD5, SHA-1, SHA-256)")) { model.checksumSelection = Set(Checksum.common) }
                        Button(L("All")) { model.checksumSelection = Set(Checksum.allCases) }
                        ForEach(Checksum.Group.allCases, id: \.self) { g in
                            Button(L("All %@", g.title)) {
                                model.checksumSelection.formUnion(Checksum.allCases.filter { $0.group == g })
                            }
                        }
                        Button(L("None")) { model.checksumSelection = [] }
                    }
                    .fixedSize()
                }
                if !model.checksumScope.isEmpty {
                    Text(model.checksumScope).foregroundStyle(.secondary)
                }
            }
            ForEach(Checksum.Group.allCases, id: \.self) { g in
                Section(g.title) {
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
                Text(c.title)
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
                    .help(L("Copy"))
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
                        .help(L("Match Case"))
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
                        .help(L("Match Case"))
                }

                TextField(placeholder, text: $model.findText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($focused)
                    .onSubmit { model.runSearch() }

                if model.searching {
                    ProgressView(value: model.progress).frame(width: 60)
                    Button(L("Stop")) { model.cancelSearch() }
                } else if let msg = model.findMessage {
                    Text(msg).foregroundStyle(.secondary).font(.callout)
                } else if !model.hits.isEmpty {
                    Text(L("%1$ld of %2$ld", (model.currentHit ?? 0) + 1, model.hits.count))
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
                    .help(L("Replace"))

                Button { model.findVisible = false } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
            }
            if model.showReplace {
                HStack(spacing: 8) {
                    Text(L("Replace with")).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
                    TextField(placeholder, text: $model.replaceText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    Button(L("Replace")) { model.replaceCurrent() }.disabled(model.currentHit == nil || model.doc.isReadOnly)
                    Button(L("All")) { model.replaceAll() }.disabled(model.hits.isEmpty || model.doc.isReadOnly)
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
        case .hex: L("Hex, e.g. 4D 5A ?? 00")
        case .text: L("Text")
        case .regex: L("Regex over bytes, e.g. \\x7fELF|[a-z]+@[a-z.]+")
        default: L("Number")
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
            .help(L("Go to Offset (⌘L)"))
            if model.offsetBase != 0 {
                sep
                field(L("Address"), hex(model.cursor + model.offsetBase))
            }
            if let s = model.selection, !s.isEmpty {
                sep
                field(L("Selection"), L("%1$@–%2$@ (%3$ld bytes)", hex(s.lowerBound), hex(s.upperBound - 1), s.count))
            }
            if let b = byteAtCursor {
                sep
                field(L("Value"), "\(b) · 0x\(String(format: "%02X", b)) · \(String(b, radix: 2).leftPad(8))")
                    .help(L("Byte under the cursor: decimal, hex, binary"))
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
                .help(L("Show Structure"))
                sep
            }
            if let r = yara.results {
                Button { send(#selector(DocumentWindowController.showYara(_:))) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "shield.lefthalf.filled").foregroundStyle(r.isEmpty ? Color.secondary : Color.pink)
                        Text(r.isEmpty ? L("YARA: nothing") : r.count == 1 ? L("YARA: %ld rule", r.count) : L("YARA: %ld rules", r.count))
                    }
                }
                .help(yara.summary)
                sep
            }
            Menu {
                Picker(L("Character Set"), selection: $model.charset) {
                    ForEach(TextEncodingView.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
            } label: { Text(model.charset.rawValue) }
            .menuStyle(.borderlessButton).fixedSize()
            .help(L("Character set of the text column"))
            sep
            Menu {
                Picker(L("Byte Order"), selection: $model.endian) {
                    Text("Little Endian").tag(Endian.little)
                    Text("Big Endian").tag(Endian.big)
                }
                .pickerStyle(.inline)
            } label: { Text(model.endian == .little ? "LE" : "BE") }
            .menuStyle(.borderlessButton).fixedSize()
            .help(L("Byte order for inspector and number search"))
            sep
            if model.doc.isReadOnly {
                Label(L("Read-Only"), systemImage: "lock.fill").foregroundStyle(.secondary)
            } else {
                Button { model.insertMode.toggle() } label: {
                    Text(model.insertMode ? L("INS") : L("OVR")).fontWeight(.medium)
                }
                .help(model.insertMode ? L("Insert mode – click for overwrite (⌘I)")
                                       : L("Overwrite mode – click for insert (⌘I)"))
            }
            sep
            Text(ByteCountFormatter.string(fromByteCount: Int64(model.doc.count), countStyle: .binary))
                .help(L("%llu bytes", model.doc.count))
            if model.doc.isModified {
                Circle().fill(Color.orange).frame(width: 7, height: 7).padding(.leading, 8)
                    .help(L("Unsaved changes"))
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
                Button(L("Cancel")) { done(nil) }.keyboardShortcut(.cancelAction)
                Button("OK") { done(text) }.keyboardShortcut(.defaultAction).disabled(!validate(text))
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
