import AppKit
import HexwerkCore
import HexwerkKaitai
import SwiftUI

/// Kaitai structure tree (SPEC FR-6.8–6.12).
struct StructureTab: View {
    @ObservedObject var model: DocumentModel
    @ObservedObject var structure: StructureModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .onAppear { structure.follow(cursor: model.cursor) }
    }

    // MARK: Header: format menu and state

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Menu {
                    formatMenu
                } label: {
                    Label(structure.formatTitle ?? "Format wählen", systemImage: "doc.text.magnifyingglass")
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                Spacer()
                if structure.parsing { ProgressView().controlSize(.small) }
                Toggle(isOn: $structure.colorize) { Image(systemName: "paintpalette") }
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .help("Felder im Hex-Raster einfärben")
            }
            if structure.stale {
                banner("Inhalt geändert", systemImage: "arrow.clockwise", tint: .orange,
                       action: ("Neu zerlegen", { structure.reparse(snapshot: model.doc.snapshot()) }))
            }
            if let e = structure.loadError {
                banner(e, systemImage: "exclamationmark.triangle.fill", tint: .red, action: nil)
            } else if let e = structure.result?.error {
                banner(e.description, systemImage: "exclamationmark.triangle.fill", tint: .red,
                       action: e.offset.map { off in ("Zur Stelle", { model.jump?(off, nil) }) })
            }
            if let r = structure.result {
                Text("\(r.nodeCount) Knoten").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
    }

    @ViewBuilder private var formatMenu: some View {
        let matches = StructureModel.catalog.matching(fileExtension: model.doc.url.pathExtension)
        if !matches.isEmpty {
            Section("Passend zur Endung") {
                ForEach(matches) { e in Button(e.title) { apply(e) } }
            }
        }
        let byCategory = Dictionary(grouping: StructureModel.catalog.entries, by: \.category)
        ForEach(byCategory.keys.sorted(), id: \.self) { cat in
            Menu(cat) {
                ForEach(byCategory[cat]!) { e in Button(e.title) { apply(e) } }
            }
        }
        if StructureModel.catalog.entries.isEmpty {
            Text("Keine Formate – im Terminal: make formats")
        }
        Divider()
        Button("Eigene .ksy öffnen …") { openOwn() }
        Button("Keins") { structure.apply(nil, title: nil, snapshot: model.doc.snapshot()) }
    }

    private func apply(_ e: FormatCatalog.Entry) {
        structure.apply(e.url, title: e.title, snapshot: model.doc.snapshot())
    }

    private func openOwn() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.message = "Kaitai-Struct-Beschreibung (.ksy) wählen"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        structure.apply(url, title: url.deletingPathExtension().lastPathComponent, snapshot: model.doc.snapshot())
    }

    private func banner(_ text: String, systemImage: String, tint: Color,
                        action: (String, () -> Void)?) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: 0)
            if let action { Button(action.0, action: action.1).controlSize(.small) }
        }
        .padding(8)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: Tree

    @ViewBuilder private var content: some View {
        if structure.result == nil && !structure.parsing {
            VStack(spacing: 8) {
                Image(systemName: "list.bullet.indent").font(.largeTitle).foregroundStyle(.tertiary)
                Text("Kein Format gewählt").foregroundStyle(.secondary)
                Text("Oben ein Format aus der Kaitai-Sammlung oder eine eigene .ksy wählen.")
                    .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(structure.rows) { row in
                            NodeRow(row: row, structure: structure) { select(row.node) }
                                .id(row.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: structure.selected) { _, id in
                    if let id { withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) } }
                }
            }
        }
    }

    private func select(_ node: ParseNode) {
        structure.selected = node.id
        if let r = node.range { model.jump?(r.lowerBound, r.isEmpty ? nil : r) }
    }
}

private struct NodeRow: View {
    let row: StructureModel.Row
    @ObservedObject var structure: StructureModel
    let onSelect: () -> Void

    var body: some View {
        let n = row.node
        let isSelected = structure.selected == n.id
        HStack(spacing: 4) {
            if !structure.hasChildren(n) {
                Color.clear.frame(width: 14)
            } else {
                Button { structure.toggle(n.id) } label: {
                    Image(systemName: structure.isExpanded(n.id) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            if n.error != nil {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.caption)
                    .help(n.error ?? "")
            }
            Text(n.name).fontWeight(structure.hasChildren(n) ? .medium : .regular).lineLimit(1)
            if !n.typeName.isEmpty {
                Text(n.typeName).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let v = n.value {
                Text(v).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
        }
        .font(.system(size: 12))
        .padding(.leading, CGFloat(row.depth) * 14 + 6)
        .padding(.trailing, 8)
        .frame(height: 22)
        .background(isSelected ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 4))
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .help(n.range.map { "0x\(String($0.lowerBound, radix: 16, uppercase: true)), \($0.count) Byte" } ?? "berechnet")
    }
}
