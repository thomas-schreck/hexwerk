import AppKit
import Combine
import HexwerkCore
import SwiftUI

/// Strings finder (SPEC FR-10.4).
@MainActor
final class StringsModel: ObservableObject {
    @Published var minLength = Settings.shared.object(forKey: "stringsMin") as? Int ?? 5 {
        didSet { Settings.shared.set(minLength, forKey: "stringsMin") }
    }
    @Published var encodings: Set<FoundString.Encoding> = [.ascii, .utf16le]
    @Published var filter = ""
    @Published private(set) var found: [FoundString]?
    @Published private(set) var running = false
    @Published private(set) var stale = false
    @Published var selected: FoundString?
    private var task: Task<Void, Never>?
    /// Marks a result stale when the content was edited while it was computed.
    private var gate = RunGate()

    var filtered: [FoundString] {
        guard let found else { return [] }
        let f = filter.trimmingCharacters(in: .whitespaces)
        return f.isEmpty ? found : found.filter { $0.text.localizedCaseInsensitiveContains(f) }
    }

    func run(_ snap: Snapshot, range: Range<UInt64>?) {
        task?.cancel()
        running = true
        let min = minLength, enc = encodings
        let ticket = gate.begin()
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let r = Strings.find(snap, range: range, minLength: min, encodings: enc, isCancelled: { Task.isCancelled })
            await MainActor.run {
                guard let self, !Task.isCancelled else { return }
                self.found = r
                self.running = false
                self.stale = self.gate.finish(ticket) == .stale
            }
        }
    }

    func cancel() { task?.cancel(); running = false }
    func contentChanged() {
        gate.contentChanged()
        if found != nil { stale = true }
    }
}

struct StringsTab: View {
    @ObservedObject var model: DocumentModel
    @ObservedObject var strings: StringsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    ForEach(FoundString.Encoding.allCases, id: \.self) { e in
                        Toggle(e.rawValue, isOn: Binding(get: { strings.encodings.contains(e) },
                                                         set: { if $0 { strings.encodings.insert(e) } else { strings.encodings.remove(e) } }))
                            .toggleStyle(.button).controlSize(.small)
                    }
                }
                HStack {
                    Stepper(L("at least %ld characters", strings.minLength), value: $strings.minLength, in: 2...64)
                        .font(.caption).fixedSize()
                    Spacer()
                    if strings.running {
                        ProgressView().controlSize(.small)
                        Button(L("Cancel")) { strings.cancel() }.controlSize(.small)
                    } else {
                        Button(model.selection == nil ? L("Search") : L("Search in Selection")) {
                            strings.run(model.doc.snapshot(), range: model.selection)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(strings.encodings.isEmpty)
                    }
                }
                TextField(L("Filter"), text: $strings.filter).textFieldStyle(.roundedBorder)
                if strings.stale {
                    Label(L("Content changed – search again"), systemImage: "arrow.clockwise")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let all = strings.found {
                    let shown = strings.filtered
                    Text(shown.count == all.count ? L("%ld strings", all.count) : L("%1$ld of %2$ld strings", shown.count, all.count))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            Divider()
            if strings.found != nil {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(strings.filtered.prefix(20_000), id: \.self) { s in row(s) }
                    }
                    .padding(.vertical, 4)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "textformat.abc").font(.largeTitle).foregroundStyle(.tertiary)
                    Text(L("Find printable strings, like strings.")).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func row(_ s: FoundString) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(hex(s.offset)).monospaced().foregroundStyle(.secondary)
            if s.encoding != .ascii {
                Text(s.encoding == .utf8 ? "U8" : s.encoding == .utf16le ? "LE" : "BE")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.purple)
            }
            Text(s.text).lineLimit(1).truncationMode(.tail)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 10).frame(height: 20)
        .background(strings.selected == s ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 4))
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            strings.selected = s
            model.jump?(s.offset, s.range)
        }
        .help(s.text)
    }
}
