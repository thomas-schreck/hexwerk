import AppKit
import HexwerkCore
import HexwerkScript
import SwiftUI

/// JavaScript editor, run button and output.
struct ScriptTab: View {
    @ObservedObject var model: DocumentModel
    @ObservedObject var script: ScriptModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Menu {
                    Button(L("Open…")) { script.open() }
                    Button(L("Save")) { script.save(as: false) }
                    Button(L("Save As…")) { script.save(as: true) }
                    Divider()
                    Section(L("Examples")) {
                        ForEach(Array(ScriptModel.examples.enumerated()), id: \.offset) { i, e in
                            Button(e.0) { script.load(example: i) }
                        }
                    }
                } label: {
                    Label(script.fileURL?.lastPathComponent ?? L("Script"), systemImage: "curlybraces")
                }
                .menuStyle(.borderlessButton).fixedSize()
                Spacer()
                if script.running {
                    ProgressView().controlSize(.small)
                    Button(L("Cancel")) { script.cancel() }.controlSize(.small)
                } else {
                    Button {
                        run()
                    } label: {
                        Label(L("Run"), systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .keyboardShortcut("r", modifiers: [.command])
                    .help(L("Run Script (⌘R)"))
                }
            }

            CodeEditor(text: $script.source)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                .frame(minHeight: 180, maxHeight: .infinity)

            if let e = script.error {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(e.description).font(.callout).textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .padding(8)
                .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            }
            if !script.status.isEmpty {
                Text(script.status).font(.caption).foregroundStyle(.secondary)
            }
            if !script.output.isEmpty {
                ScrollView {
                    Text(script.output.joined(separator: "\n"))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                }
                .frame(minHeight: 60, maxHeight: 220)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            }
            DisclosureGroup("API") {
                Text(ScriptRunner.apiHelp)
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)
        }
        .padding(10)
    }

    private func run() { model.runScript?() }
}
