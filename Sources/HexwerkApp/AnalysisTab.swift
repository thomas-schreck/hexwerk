import AppKit
import HexwerkCore
import SwiftUI

/// Entropy over the file plus byte distribution.
struct AnalysisTab: View {
    @ObservedObject var model: DocumentModel
    @ObservedObject var analysis: AnalysisModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                typeSection
                Divider()
                controls
                if let profile = analysis.profile, let stats = analysis.stats {
                    entropySection(profile)
                    statsSection(stats)
                    histogramSection(stats)
                } else if !analysis.running {
                    VStack(spacing: 8) {
                        Image(systemName: "waveform.path.ecg").font(.largeTitle).foregroundStyle(.tertiary)
                        Text(L("Compute entropy and byte distribution.")).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 30)
                }
            }
            .padding(10)
        }
        .onAppear { if analysis.stats == nil && !analysis.running && model.doc.count <= 256 << 20 { run(selection: false) } }
    }

    // MARK: File type and embedded files

    private var typeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("File Type")).font(.headline)
            Text(analysis.typeDescription ?? "…").font(.callout).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let m = analysis.mime { Text(m).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            if let s = analysis.signature {
                Text(L("Signature: %@", s.title) + (s.kaitai.map { " · Kaitai \($0)" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text(L("Embedded Files")).font(.subheadline.weight(.semibold))
                Spacer()
                if analysis.embeddedRunning { ProgressView().controlSize(.small) }
                Button(L("Search")) { analysis.scanEmbedded(model.doc.snapshot()) }
                    .controlSize(.small).disabled(analysis.embeddedRunning)
                    .help(L("Search for signatures of known formats at every offset (like binwalk)"))
            }
            .padding(.top, 4)
            if let e = analysis.embedded {
                if e.isEmpty {
                    Text(L("Nothing found")).font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(e.prefix(500).enumerated()), id: \.offset) { _, h in
                        Button {
                            model.jump?(h.offset, nil)
                        } label: {
                            HStack {
                                Text(hex(h.offset)).monospaced()
                                Text(h.title)
                                Spacer()
                                if h.kaitai != nil { Image(systemName: "list.bullet.indent").foregroundStyle(.tertiary) }
                            }
                            .font(.caption)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if e.count > 500 { Text(L("… %ld more", e.count - 500)).font(.caption).foregroundStyle(.tertiary) }
                    if e.count >= FileSignatures.maxEmbeddedHits {
                        Text(L("stopped after %ld hits", FileSignatures.maxEmbeddedHits)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if analysis.running {
                    ProgressView(value: analysis.progress).controlSize(.small)
                    Button(L("Cancel")) { analysis.cancel() }.controlSize(.small)
                } else {
                    Button {
                        run(selection: false)
                    } label: {
                        Label(L("Whole File"), systemImage: "waveform.path.ecg")
                    }
                    Button(L("Selection")) { run(selection: true) }.disabled(model.selection == nil)
                    Spacer()
                }
            }
            .controlSize(.small)
            if analysis.stale {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise").foregroundStyle(.orange)
                    Text(L("Content changed")).font(.callout)
                    Spacer()
                    Button(L("Recompute")) { run(selection: false) }.controlSize(.small)
                }
                .padding(8)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func run(selection: Bool) {
        analysis.run(model.doc.snapshot(), range: selection ? model.selection : nil)
    }

    // MARK: Entropy chart

    private func entropySection(_ p: EntropyProfile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L("Entropy")).font(.headline)
                Spacer()
                if let i = analysis.hoverBlock, p.blocks.indices.contains(i) {
                    let r = p.range(ofBlock: i, total: analysis.end)
                    Text("\(hex(r.lowerBound)): \(String(format: "%.2f", p.blocks[i]))")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                } else {
                    Text(L("per %@", ByteCountFormatter.string(fromByteCount: Int64(p.blockSize), countStyle: .binary)))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            GeometryReader { geo in
                Canvas { ctx, size in drawEntropy(ctx, size, p) }
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        if case .active(let pt) = phase {
                            analysis.hoverBlock = block(at: pt.x, width: geo.size.width, p)
                        } else {
                            analysis.hoverBlock = nil
                        }
                    }
                    .onTapGesture { pt in
                        let i = block(at: pt.x, width: geo.size.width, p)
                        model.jump?(p.range(ofBlock: i, total: analysis.end).lowerBound, nil)
                    }
            }
            .frame(height: 110)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Text(hex(p.start)); Spacer(); Text(hex(analysis.end))
            }
            .font(.caption2).monospaced().foregroundStyle(.tertiary)
            Text(L("High (> 7.5): compressed or encrypted. Low: padding, tables, text."))
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func block(at x: CGFloat, width: CGFloat, _ p: EntropyProfile) -> Int {
        min(p.blocks.count - 1, max(0, Int(x / max(1, width) * CGFloat(p.blocks.count))))
    }

    private func drawEntropy(_ ctx: GraphicsContext, _ size: CGSize, _ p: EntropyProfile) {
        guard !p.blocks.isEmpty else { return }
        let n = CGFloat(p.blocks.count)
        func y(_ e: Double) -> CGFloat { size.height - 4 - CGFloat(e / 8) * (size.height - 8) }
        // Guide lines at 4 and 7.5 bits.
        for g in [4.0, 7.5] {
            var l = Path()
            l.move(to: CGPoint(x: 0, y: y(g))); l.addLine(to: CGPoint(x: size.width, y: y(g)))
            ctx.stroke(l, with: .color(.secondary.opacity(0.25)), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
        }
        var area = Path()
        area.move(to: CGPoint(x: 0, y: size.height))
        for (i, e) in p.blocks.enumerated() {
            let x0 = CGFloat(i) / n * size.width, x1 = CGFloat(i + 1) / n * size.width
            area.addLine(to: CGPoint(x: x0, y: y(e)))
            area.addLine(to: CGPoint(x: x1, y: y(e)))
        }
        area.addLine(to: CGPoint(x: size.width, y: size.height))
        area.closeSubpath()
        ctx.fill(
            area,
            with: .linearGradient(
                Gradient(colors: [.red.opacity(0.75), .orange.opacity(0.6), .teal.opacity(0.5)]),
                startPoint: CGPoint(x: 0, y: y(8)), endPoint: CGPoint(x: 0, y: y(0))))
        // Cursor position.
        let total = analysis.end - p.start
        if total > 0, model.cursor >= p.start, model.cursor < analysis.end {
            let x = CGFloat(Double(model.cursor - p.start) / Double(total)) * size.width
            var c = Path()
            c.move(to: CGPoint(x: x, y: 0)); c.addLine(to: CGPoint(x: x, y: size.height))
            ctx.stroke(c, with: .color(.accentColor), lineWidth: 1.5)
        }
        if let h = analysis.hoverBlock {
            let r = CGRect(x: CGFloat(h) / n * size.width, y: 0, width: max(1, size.width / n), height: size.height)
            ctx.fill(Path(r), with: .color(.primary.opacity(0.15)))
        }
    }

    // MARK: Statistics

    private func statsSection(_ s: ByteStats) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            row(L("Entropy"), L("%.4f bits/byte", s.entropy))
            row("Bytes", "\(s.count)")
            row(L("Distinct"), L("%ld of 256", s.distinct))
            row("0x00", percent(s.zeroRatio))
            row(L("Printable"), percent(s.printableRatio))
            row("≥ 0x80", percent(s.highRatio))
        }
        .font(.callout)
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).monospacedDigit().textSelection(.enabled)
        }
    }

    private func percent(_ r: Double) -> String { String(format: "%.1f %%", r * 100) }

    // MARK: Histogram

    private func histogramSection(_ s: ByteStats) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L("Byte Distribution")).font(.headline)
                Spacer()
                if let b = analysis.hoverByte {
                    Text(String(format: "0x%02X: %llu", b, s.histogram[b])).font(.caption).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Toggle("log", isOn: $analysis.logScale).toggleStyle(.button).controlSize(.mini)
                    .help(L("Logarithmic scale"))
            }
            GeometryReader { geo in
                Canvas { ctx, size in drawHistogram(ctx, size, s) }
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        if case .active(let pt) = phase {
                            analysis.hoverByte = min(255, max(0, Int(pt.x / max(1, geo.size.width) * 256)))
                        } else {
                            analysis.hoverByte = nil
                        }
                    }
            }
            .frame(height: 90)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            // Labels at their real byte positions (printable ASCII is 0x20–0x7E).
            GeometryReader { geo in
                ForEach([0x00, 0x20, 0x7F, 0xFF], id: \.self) { b in
                    Text(String(format: "%02X", b))
                        .position(x: min(geo.size.width - 8, max(8, CGFloat(b) / 256 * geo.size.width)), y: 6)
                }
            }
            .frame(height: 12)
            .font(.caption2).monospaced().foregroundStyle(.tertiary)
        }
    }

    private func drawHistogram(_ ctx: GraphicsContext, _ size: CGSize, _ s: ByteStats) {
        let maxV = Double(s.histogram.max() ?? 0)
        guard maxV > 0 else { return }
        let w = size.width / 256
        for (b, c) in s.histogram.enumerated() where c > 0 {
            let f = analysis.logScale ? log(Double(c) + 1) / log(maxV + 1) : Double(c) / maxV
            let h = max(1, CGFloat(f) * (size.height - 4))
            let color: Color = b == 0 ? .gray : (0x20 ... 0x7E).contains(b) ? .teal : b >= 0x80 ? .purple : .orange
            ctx.fill(
                Path(CGRect(x: CGFloat(b) * w, y: size.height - h, width: max(1, w - 0.3), height: h)),
                with: .color(analysis.hoverByte == b ? .accentColor : color.opacity(0.8)))
        }
    }
}
