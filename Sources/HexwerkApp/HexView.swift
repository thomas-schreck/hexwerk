import AppKit
import HexwerkCore

/// The hex grid: column header, offset column, hex bytes, characters.
/// Draws only the rows on screen and keeps its own scroll position as a row
/// index, because an NSScrollView document of billions of pixels loses
/// precision.
final class HexView: NSView, NSMenuItemValidation {
    enum Pane { case hex, text }

    unowned let model: DocumentModel
    var document: Document { model.doc }

    private(set) var cursor: UInt64 = 0
    private(set) var anchor: UInt64?  // selection start while selecting
    private var lowNibble = false  // typing the second hex digit
    private var pane: Pane = .hex
    private var topRow: UInt64 = 0
    private var scrollRemainder: CGFloat = 0

    private let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    private let headerFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium)
    private lazy var charW: CGFloat = ("0" as NSString).size(withAttributes: [.font: font]).width
    private lazy var lineH: CGFloat = ceil(font.ascender - font.descender + font.leading) + 5
    private let scroller = NSScroller()
    private let inset: CGFloat = 12

    init(model: DocumentModel) {
        self.model = model
        super.init(frame: .zero)
        scroller.scrollerStyle = .overlay
        scroller.target = self
        scroller.action = #selector(scrollerMoved)
        addSubview(scroller)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    /// Re-syncs after the document changed underneath (undo, save, replace).
    func reload() {
        cursor = min(cursor, document.count)
        if let a = anchor, a > document.count { anchor = nil }
        lowNibble = false
        clampTop()
        changed(content: true)
    }

    /// Moves the cursor (and optionally selects), scrolling it into view.
    func jump(to offset: UInt64, select: Range<UInt64>?) {
        if let r = select, !r.isEmpty {
            anchor = r.lowerBound
            cursor = r.upperBound - 1
        } else {
            anchor = nil
            cursor = min(offset, document.count)
        }
        lowNibble = false
        // Put the target a few rows below the top instead of at the edge.
        let row = cursor / UInt64(bytesPerRow)
        if row < topRow || row >= topRow + UInt64(visibleRows) {
            topRow = row > 3 ? row - 3 : 0
        }
        clampTop()
        changed()
    }

    // MARK: Geometry

    var bytesPerRow: Int {
        if model.bytesPerRowSetting > 0 { return model.bytesPerRowSetting }
        // Fit: each byte costs three hex cells, one text cell, plus group gaps.
        let free = bounds.width - textX(for: 0) - inset * 2
        let perByte = charW * (4 + 1.0 / 8)
        return max(8, Int(free / perByte) / 8 * 8)
    }

    /// One extra position past the last byte, where typing appends.
    private var rowCount: UInt64 { document.count / UInt64(bytesPerRow) + 1 }
    private var headerH: CGFloat { lineH + 4 }
    private var visibleRows: Int { max(1, Int((bounds.height - headerH) / lineH)) }
    private var offsetDigits: Int {
        let top = model.addresses.address(of: document.count)
        return model.decimalOffsets ? max(10, String(top).count) : max(8, String(top, radix: 16).count)
    }
    private var offsetColW: CGFloat { inset + CGFloat(offsetDigits) * charW + inset }
    private var hexX: CGFloat { offsetColW + inset }
    private func hexColX(_ c: Int) -> CGFloat { hexX + CGFloat(c * 3 + c / 8) * charW }
    private func textX(for width: Int) -> CGFloat { hexColX(width) + charW * 1.5 }
    private var textX: CGFloat { textX(for: bytesPerRow) }
    private func rowY(_ row: UInt64) -> CGFloat { headerH + CGFloat(row - topRow) * lineH }

    var selection: Range<UInt64>? {
        guard let anchor, anchor != cursor else { return nil }
        // anchor/cursor can briefly lie beyond the end after the document
        // shrank underneath (#5); never build an inverted range from them.
        let lo = min(anchor, cursor), hi = min(document.count, max(anchor, cursor) + 1)
        return lo < hi ? lo ..< hi : nil
    }

    override func layout() {
        super.layout()
        let w = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay)
        scroller.frame = NSRect(x: bounds.width - w, y: headerH, width: w, height: bounds.height - headerH)
        clampTop()
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Resolve dynamic colors for this view's appearance, also offscreen.
        effectiveAppearance.performAsCurrentDrawingAppearance { drawGrid() }
    }

    private func drawGrid() {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()

        let w = UInt64(bytesPerRow)
        let first = topRow
        let last = min(rowCount, topRow + UInt64(visibleRows) + 1)
        let start = first * w
        let end = min(document.count, last * w)
        // Up to 3 bytes before the window give the UTF-8 decoder context for
        // a character whose first bytes scrolled off the top.
        let ctxStart = start >= 3 ? start - 3 : 0
        let raw = [UInt8](start < end ? document.read(ctxStart ..< end) : Data())
        let lead = Int(start - ctxStart)
        let bytes = raw.count > lead ? Array(raw[lead...]) : []
        let cells = raw.count > lead ? TextCells.decode(raw, from: lead, as: model.charset) : []
        var wide: [(String, NSRect)] = []

        // Offset column band and zebra rows.
        NSColor.underPageBackgroundColor.withAlphaComponent(0.35).setFill()
        NSRect(x: 0, y: headerH, width: offsetColW, height: bounds.height).fill()
        NSColor.separatorColor.withAlphaComponent(0.5).setFill()
        NSRect(x: offsetColW - 1, y: headerH, width: 1, height: bounds.height).fill()
        // A faint tint of the text color works in light and dark mode alike.
        NSColor.labelColor.withAlphaComponent(0.035).setFill()
        for row in first ..< last where row % 2 == 1 {
            NSRect(x: offsetColW, y: rowY(row), width: bounds.width - offsetColW, height: lineH).fill()
        }

        // Highlights, selection, cursor.
        let window = start ..< max(end, start + 1)
        for (r, color) in model.highlights(in: window) { fill(r, color, in: window) }
        if let sel = selection {
            let accent = NSColor.controlAccentColor
            fill(sel, accent.withAlphaComponent(pane == .hex ? 0.32 : 0.14), in: window, only: .hex)
            fill(sel, accent.withAlphaComponent(pane == .text ? 0.32 : 0.14), in: window, only: .text)
        }
        drawCursor()

        // Text. Zero bytes and unprintable characters are dimmed, so the eye
        // finds the interesting bytes faster.
        let off: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        for row in first ..< last {
            let y = rowY(row) + 2
            let rowStart = Int((row - first) * w)
            guard rowStart <= bytes.count else { break }
            let slice = bytes[rowStart ..< min(rowStart + bytesPerRow, bytes.count)]

            (offsetString(row * w) as NSString).draw(at: NSPoint(x: inset, y: y), withAttributes: off)

            // Monospaced grid: put glyphs at fixed positions and skip text
            // layout entirely. Attributed strings with color runs cost ~3x.
            let baseline = y + font.ascender
            var coveredUntil = 0  // text cells taken by a multi-byte char
            for (i, b) in slice.enumerated() {
                let x = hexColX(i)
                let pair = hexGlyphs[Int(b)]
                let isDim = b == 0
                append(pair.0, NSPoint(x: x, y: baseline), dim: isDim)
                append(pair.1, NSPoint(x: x + charW, y: baseline), dim: isDim)

                let tx = textX + CGFloat(i) * charW
                switch cells[rowStart + i] {
                case .char(let ch, let span):
                    if span == 1, ch.isASCII, let a = ch.asciiValue {
                        append(asciiGlyphs[Int(a)], NSPoint(x: tx, y: baseline), dim: false)
                    } else {
                        // Centered over all its bytes; width is capped at the row end.
                        let cellsAvail = min(span, bytesPerRow - i)
                        wide.append((String(ch), NSRect(x: tx, y: y, width: CGFloat(cellsAvail) * charW, height: lineH)))
                        coveredUntil = i + span
                    }
                case .continuation where i < coveredUntil:
                    break  // drawn as part of the character
                case .continuation, .unprintable:
                    append(dotGlyph, NSPoint(x: tx, y: baseline), dim: true)
                }
            }
        }
        flushGlyphs()
        drawWide(wide)
        drawHeader()
    }

    // MARK: Glyph drawing

    private lazy var ctFont: CTFont = font as CTFont
    private var glyphs: [CGGlyph] = [], positions: [CGPoint] = []
    private var dimGlyphs: [CGGlyph] = [], dimPositions: [CGPoint] = []

    private func glyph(for c: Character) -> CGGlyph {
        var units = Array(String(c).utf16)
        var g = [CGGlyph](repeating: 0, count: units.count)
        CTFontGetGlyphsForCharacters(ctFont, &units, &g, units.count)
        return g[0]
    }

    private lazy var hexGlyphs: [(CGGlyph, CGGlyph)] = {
        let digits = Array("0123456789ABCDEF").map { glyph(for: $0) }
        return (0 ... 255).map { (digits[$0 >> 4], digits[$0 & 0xF]) }
    }()
    private lazy var asciiGlyphs: [CGGlyph] = (0 ... 255).map { glyph(for: Character(UnicodeScalar(UInt8($0)))) }
    private lazy var dotGlyph = glyph(for: "·")

    /// Non-ASCII characters go through normal text drawing: it handles font
    /// fallback (CJK, emoji) and they are rare enough not to cost much.
    private func drawWide(_ items: [(String, NSRect)]) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        for (text, rect) in items {
            let w = (text as NSString).size(withAttributes: attrs).width
            (text as NSString).draw(at: NSPoint(x: rect.midX - w / 2, y: rect.minY + 2), withAttributes: attrs)
        }
    }

    /// Positions are given in text space, which the flipped text matrix
    /// mirrors as well, so y goes in negated.
    private func append(_ g: CGGlyph, _ p: NSPoint, dim: Bool) {
        let tp = CGPoint(x: p.x, y: -p.y)
        if dim { dimGlyphs.append(g); dimPositions.append(tp) } else { glyphs.append(g); positions.append(tp) }
    }

    private func flushGlyphs() {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)  // view is flipped
        for (g, p, color) in [(glyphs, positions, NSColor.labelColor), (dimGlyphs, dimPositions, NSColor.tertiaryLabelColor)] {
            ctx.setFillColor(color.cgColor)
            CTFontDrawGlyphs(ctFont, g, p, g.count, ctx)
        }
        ctx.restoreGState()
        glyphs.removeAll(keepingCapacity: true); positions.removeAll(keepingCapacity: true)
        dimGlyphs.removeAll(keepingCapacity: true); dimPositions.removeAll(keepingCapacity: true)
    }

    /// Offsets are shown as addresses when the file has a base address.
    private func offsetString(_ offset: UInt64) -> String {
        let v = model.addresses.address(of: offset)
        return model.decimalOffsets ? String(v).leftPad(offsetDigits, " ") : String(v, radix: 16, uppercase: true).leftPad(offsetDigits)
    }

    private func drawHeader() {
        NSColor.windowBackgroundColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: headerH).fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: headerH - 1, width: bounds.width, height: 1).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: headerFont, .foregroundColor: NSColor.secondaryLabelColor]
        let y = (headerH - headerFont.boundingRectForFont.height) / 2
        ((model.offsetBase != 0 ? L("Address") : model.decimalOffsets ? L("Offset (dec)") : "Offset") as NSString).draw(
            at: NSPoint(x: inset, y: y), withAttributes: attrs)
        let cursorCol = Int(cursor % UInt64(bytesPerRow))
        for c in 0 ..< bytesPerRow {
            let label = String(format: "%02X", c)
            var a = attrs
            if c == cursorCol { a[.foregroundColor] = NSColor.controlAccentColor }
            let lw = (label as NSString).size(withAttributes: a).width
            (label as NSString).draw(at: NSPoint(x: hexColX(c) + (charW * 2 - lw) / 2, y: y), withAttributes: a)
        }
        // One digit per text cell: the header font is smaller than the grid
        // font, so drawing the digits as one string would drift out of line.
        for c in 0 ..< bytesPerRow {
            let label = String(c % 16, radix: 16, uppercase: true)
            var a = attrs
            if c == cursorCol { a[.foregroundColor] = NSColor.controlAccentColor }
            let lw = (label as NSString).size(withAttributes: a).width
            (label as NSString).draw(at: NSPoint(x: textX + CGFloat(c) * charW + (charW - lw) / 2, y: y), withAttributes: a)
        }
    }

    /// Fills the cells of `range` with rounded rects, limited to `window`.
    private func fill(_ range: Range<UInt64>, _ color: NSColor, in window: Range<UInt64>, only: Pane? = nil) {
        let r = range.clamped(to: window)
        guard !r.isEmpty else { return }
        color.setFill()
        let w = UInt64(bytesPerRow)
        var pos = r.lowerBound
        while pos < r.upperBound {
            let row = pos / w
            let c0 = Int(pos % w)
            let c1 = Int(min(r.upperBound, (row + 1) * w) - row * w)  // exclusive
            let y = rowY(row) + 1
            if only != .text {
                let x0 = hexColX(c0) - charW * 0.35
                let x1 = hexColX(c1 - 1) + charW * 2.35
                NSBezierPath(roundedRect: NSRect(x: x0, y: y, width: x1 - x0, height: lineH - 2), xRadius: 3, yRadius: 3).fill()
            }
            if only != .hex {
                NSBezierPath(
                    roundedRect: NSRect(x: textX + CGFloat(c0) * charW, y: y, width: CGFloat(c1 - c0) * charW, height: lineH - 2),
                    xRadius: 3, yRadius: 3
                ).fill()
            }
            pos = (row + 1) * w
        }
    }

    private func drawCursor() {
        let row = cursor / UInt64(bytesPerRow)
        guard row >= topRow, row < topRow + UInt64(visibleRows) + 1 else { return }
        let c = Int(cursor % UInt64(bytesPerRow))
        let y = rowY(row) + 1
        let accent = NSColor.controlAccentColor
        let hexRect = NSRect(x: hexColX(c) + (lowNibble ? charW : 0) - 2, y: y, width: (lowNibble ? 1 : 2) * charW + 4, height: lineH - 2)
        let textRect = NSRect(x: textX + CGFloat(c) * charW - 1, y: y, width: charW + 2, height: lineH - 2)
        for (rect, active) in [(hexRect, pane == .hex), (textRect, pane == .text)] {
            let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
            if active {
                accent.withAlphaComponent(0.25).setFill()
                path.fill()
                if model.insertMode {
                    // Insert mode: a bar in front of the byte instead of a box.
                    accent.setFill()
                    NSRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height).fill()
                } else {
                    accent.setStroke()
                    path.lineWidth = 1.5
                    path.stroke()
                }
            } else {
                NSColor.tertiaryLabelColor.setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        }
    }

    // MARK: Scrolling

    private func clampTop() {
        let maxTop = rowCount > UInt64(visibleRows) ? rowCount - UInt64(visibleRows) : 0
        topRow = min(topRow, maxTop)
        updateScroller()
        needsDisplay = true
    }

    private func updateScroller() {
        let vis = Double(visibleRows), total = Double(rowCount)
        scroller.knobProportion = CGFloat(min(1, vis / max(total, 1)))
        scroller.doubleValue = min(1, Double(topRow) / max(1, total - vis))
        scroller.isEnabled = total > vis
        scroller.isHidden = total <= vis
    }

    @objc private func scrollerMoved() {
        let maxTop = rowCount > UInt64(visibleRows) ? rowCount - UInt64(visibleRows) : 0
        switch scroller.hitPart {
        case .decrementLine: scroll(by: -1)
        case .incrementLine: scroll(by: 1)
        case .decrementPage: scroll(by: -Int64(visibleRows))
        case .incrementPage: scroll(by: Int64(visibleRows))
        default:
            topRow = UInt64((scroller.doubleValue * Double(maxTop)).rounded())
            clampTop()
        }
    }

    private func scroll(by rows: Int64) {
        if rows < 0 { topRow -= min(topRow, UInt64(-rows)) } else { topRow += UInt64(rows) }
        clampTop()
    }

    override func scrollWheel(with event: NSEvent) {
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / lineH : event.scrollingDeltaY * 3
        scrollRemainder += dy
        let rows = Int64(scrollRemainder.rounded(.towardZero))
        scrollRemainder -= CGFloat(rows)
        if rows != 0 { scroll(by: -rows) }
    }

    private func ensureCursorVisible() {
        let row = cursor / UInt64(bytesPerRow)
        if row < topRow { topRow = row } else if row >= topRow + UInt64(visibleRows) { topRow = row - UInt64(visibleRows) + 1 }
        clampTop()
    }

    // MARK: Mouse

    private func position(at p: NSPoint) -> (UInt64, Pane)? {
        let y = max(p.y, headerH)
        let row = topRow + UInt64((y - headerH) / lineH)
        let col: Int
        let hitPane: Pane
        if p.x >= textX - charW / 2 {
            col = Int((p.x - textX) / charW)
            hitPane = .text
        } else if p.x >= hexX - charW / 2 {
            let rel = (p.x - hexX) / charW
            col = (0 ..< bytesPerRow).first { rel < CGFloat($0 * 3 + $0 / 8) + 2.5 } ?? bytesPerRow - 1
            hitPane = .hex
        } else {
            return nil
        }
        let offset = row * UInt64(bytesPerRow) + UInt64(max(0, min(col, bytesPerRow - 1)))
        return (min(offset, document.count), hitPane)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let (offset, hitPane) = position(at: convert(event.locationInWindow, from: nil)) else { return }
        pane = hitPane
        if event.modifierFlags.contains(.shift) {
            if anchor == nil { anchor = cursor }
        } else {
            anchor = offset
        }
        cursor = offset
        lowNibble = false
        changed()
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if p.y < headerH { scroll(by: -1) } else if p.y > bounds.height { scroll(by: 1) }
        guard let (offset, _) = position(at: p) else { return }
        cursor = offset
        changed()
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        let cmd = event.modifierFlags.contains(.command)
        if model.vimEnabled, !cmd, handleVim(event) { return }
        let w = UInt64(bytesPerRow)
        let page = UInt64(visibleRows) * w

        if let key = event.specialKey {
            switch key {
            case .leftArrow: move(to: cursor > 0 ? cursor - 1 : 0, extend: shift)
            case .rightArrow: move(to: min(document.count, cursor + 1), extend: shift)
            case .upArrow: move(to: cmd ? 0 : (cursor >= w ? cursor - w : cursor), extend: shift)
            case .downArrow: move(to: cmd ? document.count : min(document.count, cursor + w), extend: shift)
            case .pageUp: move(to: cursor >= page ? cursor - page : 0, extend: shift)
            case .pageDown: move(to: min(document.count, cursor + page), extend: shift)
            case .home: move(to: cmd ? 0 : cursor - cursor % w, extend: shift)
            case .end: move(to: cmd ? document.count : min(document.count, cursor - cursor % w + w - 1), extend: shift)
            case .tab, .backTab:
                // Tab goes hex → text → next control, Shift-Tab back; Ctrl-Tab
                // always leaves the grid (macOS convention), so focus is never trapped.
                let back = key == .backTab || shift
                if event.modifierFlags.contains(.control) || pane == (back ? .hex : .text) {
                    if back { window?.selectPreviousKeyView(self) } else { window?.selectNextKeyView(self) }
                    return
                }
                pane = back ? .hex : .text
                lowNibble = false
                changed()
            case .delete: deleteBackward()
            case .deleteForward: deleteForward()
            default: super.keyDown(with: event)
            }
            return
        }
        guard !cmd, let chars = event.characters, chars.count == 1, let ch = chars.unicodeScalars.first,
            ch.value >= 0x20
        else {
            super.keyDown(with: event)
            return
        }
        switch pane {
        case .hex:
            guard let digit = UInt8(String(ch), radix: 16) else { NSSound.beep(); return }
            typeNibble(digit)
        case .text:
            guard let bytes = encodeTyped(chars) else { NSSound.beep(); return }
            typeBytes(bytes)
        }
    }

    private func move(to offset: UInt64, extend: Bool) {
        if extend { if anchor == nil { anchor = cursor } } else { anchor = nil }
        cursor = offset
        lowNibble = false
        ensureCursorVisible()
        changed()
    }

    private func typeNibble(_ digit: UInt8) {
        guard !document.isReadOnly else { NSSound.beep(); return }
        if lowNibble {
            // The second digit always edits the byte just started and joins
            // its undo step, so one undo takes back the whole byte.
            let old = document.read(cursor ..< cursor + 1).first ?? 0
            edit { try document.amendingLastEdit { try document.overwrite(at: cursor, with: Data([(old & 0xF0) | digit])) } }
            cursor += 1
            lowNibble = false
        } else if model.insertMode || cursor >= document.count {
            let at = selection?.lowerBound ?? cursor
            edit {
                try document.grouped {
                    if let sel = selection { try document.delete(sel) }
                    try document.insert(Data([digit << 4]), at: at)
                }
            }
            cursor = at
            lowNibble = true
        } else {
            let old = document.read(cursor ..< cursor + 1).first ?? 0
            edit { try document.overwrite(at: cursor, with: Data([(digit << 4) | (old & 0x0F)])) }
            lowNibble = true
        }
        anchor = nil
        ensureCursorVisible()
        changed(content: true)
    }

    /// Bytes for a typed character in the current text encoding, nil if it
    /// cannot be represented (e.g. "ä" in ASCII).
    private func encodeTyped(_ s: String) -> Data? {
        switch model.charset {
        case .utf8: return Data(s.utf8)
        case .ascii: return s.unicodeScalars.allSatisfy { $0.isASCII } ? Data(s.utf8) : nil
        case .latin1:
            let v = s.unicodeScalars.map(\.value)
            return v.allSatisfy { $0 <= 0xFF } ? Data(v.map { UInt8($0) }) : nil
        }
    }

    private func typeBytes(_ bytes: Data) {
        guard !document.isReadOnly else { NSSound.beep(); return }
        if let sel = selection, model.insertMode {
            edit { try document.replace(sel, with: bytes) }
            cursor = sel.lowerBound
        } else if model.insertMode {
            edit { try document.insert(bytes, at: cursor) }
        } else {
            edit { try document.overwrite(at: cursor, with: bytes) }
        }
        cursor += UInt64(bytes.count)
        anchor = nil
        lowNibble = false
        ensureCursorVisible()
        changed(content: true)
    }

    private func deleteBackward() {
        guard !document.isReadOnly else { NSSound.beep(); return }
        if let sel = selection {
            edit { try document.delete(sel) }
            cursor = sel.lowerBound
        } else if cursor > 0 {
            edit { try document.delete(cursor - 1 ..< cursor) }
            cursor -= 1
        } else {
            NSSound.beep(); return
        }
        anchor = nil
        lowNibble = false
        ensureCursorVisible()
        changed(content: true)
    }

    /// x / d: deletes the selection, else the byte under the cursor.
    fileprivate func deleteSelectionOrByte() { deleteForward() }

    private func deleteForward() {
        guard !document.isReadOnly else { NSSound.beep(); return }
        if let sel = selection {
            edit { try document.delete(sel) }
            cursor = sel.lowerBound
        } else if cursor < document.count {
            edit { try document.delete(cursor ..< cursor + 1) }
        } else {
            NSSound.beep(); return
        }
        anchor = nil
        lowNibble = false
        changed(content: true)
    }

    /// Runs an edit; errors just beep.
    private func edit(_ body: () throws -> Void) {
        do { try body() } catch { NSSound.beep() }
    }

    private func changed(content: Bool = false) {
        cursor = min(cursor, document.count)
        needsDisplay = true
        if content { model.contentChanged() }
        model.cursorMoved(cursor, selection: selection)
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    // MARK: Accessibility

    // The grid is drawn, not made of controls: VoiceOver gets one element
    // whose value describes the cursor byte, its row and the selection.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override func accessibilityRoleDescription() -> String? { L("hex editor") }
    override func accessibilityLabel() -> String? {
        pane == .hex ? L("Hex bytes") : L("Text characters")
    }
    override func accessibilityValue() -> Any? { accessibilitySummary }
    override func accessibilityNumberOfCharacters() -> Int { accessibilitySummary.count }
    override func accessibilitySelectedTextRange() -> NSRange { NSRange(location: 0, length: 0) }
    override func isAccessibilityEnabled() -> Bool { true }

    private var accessibilitySummary: String {
        let w = UInt64(bytesPerRow)
        let rowStart = cursor - cursor % w
        let row = document.read(rowStart ..< rowStart + w)
        let byte: String
        if cursor < document.count, let b = document.read(cursor ..< cursor + 1).first {
            let ch = (0x20 ... 0x7E).contains(b) ? String(UnicodeScalar(b)) : "·"
            byte = L("byte %1$@, %2$@", String(format: "%02X", b), ch)
        } else {
            byte = L("end of file")
        }
        var parts = [L("Offset %1$@, %2$@", hex(cursor), byte)]
        if let sel = selection { parts.append(L("%ld bytes selected", sel.count)) }
        if !row.isEmpty {
            parts.append(L("Row %1$@: %2$@", hex(rowStart), row.map { String(format: "%02X", $0) }.joined(separator: " ")))
        }
        return parts.joined(separator: ". ")
    }

    // MARK: Menu actions

    @objc func undo(_ sender: Any?) { document.undo(); reload() }
    @objc func redo(_ sender: Any?) { document.redo(); reload() }

    @objc func copy(_ sender: Any?) {
        let range = selection ?? (cursor < document.count ? cursor ..< cursor + 1 : nil)
        guard let range else { return }
        // Cap so a careless Cmd-A + Cmd-C on a huge file stays harmless.
        let limit: UInt64 = 16 << 20
        let data = document.read(range.lowerBound ..< min(range.upperBound, range.lowerBound + limit))
        let text =
            pane == .hex
            ? data.map { String(format: "%02X", $0) }.joined(separator: " ")
            : String(decoding: data.map { (0x20 ... 0x7E).contains($0) ? $0 : 0x2E }, as: UTF8.self)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func cut(_ sender: Any?) {
        guard selection != nil else { return }
        copy(sender)
        deleteBackward()
    }

    /// Hex text (in the hex pane) or raw text (in the text pane). Replaces a
    /// selection, inserts in insert mode, otherwise overwrites from the cursor.
    @objc func paste(_ sender: Any?) {
        guard !document.isReadOnly, let s = NSPasteboard.general.string(forType: .string) else { return }
        let bytes: Data
        if pane == .hex, let p = SearchPattern.hex(s),
            case let fixed = p.elements.compactMap({ if case .byte(let b) = $0 { b } else { nil } }),
            fixed.count == p.count
        {
            bytes = Data(fixed)
        } else {
            bytes = Data(s.utf8)
        }
        if let sel = selection {
            edit { try document.replace(sel, with: bytes) }
            cursor = sel.lowerBound + UInt64(bytes.count)
        } else if model.insertMode {
            edit { try document.insert(bytes, at: cursor) }
            cursor += UInt64(bytes.count)
        } else {
            edit { try document.overwrite(at: cursor, with: bytes) }
            cursor += UInt64(bytes.count)
        }
        anchor = nil
        ensureCursorVisible()
        changed(content: true)
    }

    @objc override func selectAll(_ sender: Any?) {
        guard document.count > 0 else { return }
        anchor = 0
        cursor = document.count - 1
        changed()
    }

    /// Fills the selection with a repeated byte pattern (one undo step).
    func fillSelection(with pattern: Data) {
        guard let sel = selection, !pattern.isEmpty else { NSSound.beep(); return }
        let bytes = FillPattern.bytes(pattern, count: sel.count)
        edit { try document.replace(sel, with: bytes) }
        changed(content: true)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): document.canUndo
        case #selector(redo(_:)): document.canRedo
        case #selector(copy(_:)): document.count > 0
        case #selector(cut(_:)): selection != nil && !document.isReadOnly
        case #selector(paste(_:)): !document.isReadOnly && NSPasteboard.general.string(forType: .string) != nil
        default: true
        }
    }

    // MARK: Snapshot (testing)

    /// Used by `HexwerkApp --snapshot` to render a given row offscreen.
    func scroll(toRow row: UInt64) {
        topRow = row
        clampTop()
    }
}

// MARK: - Vim mode

extension HexView {
    /// Returns true if the vim layer consumed the key.
    fileprivate func handleVim(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 {  // Esc
            runVim(model.vim.escape())
            return true
        }
        guard model.vim.handlesTyping else { return false }  // insert/replace: normal typing
        if event.specialKey != nil { return false }  // arrows, page keys … work as usual
        let ctrl = event.modifierFlags.contains(.control)
        guard let chars = event.charactersIgnoringModifiers, chars.count == 1, let ch = chars.first else { return false }
        runVim(model.vim.key(ch, control: ctrl))
        return true
    }

    fileprivate func runVim(_ actions: [VimAction]) {
        let w = UInt64(bytesPerRow)
        let visual = model.vim.mode == .visual
        func clamp(_ v: Int64) -> UInt64 { UInt64(max(0, min(Int64(document.count), v))) }
        for a in actions {
            switch a {
            case .moveBytes(let n): move(to: clamp(Int64(cursor) + n), extend: visual)
            case .moveRows(let n): move(to: clamp(Int64(cursor) + n * Int64(w)), extend: visual)
            case .movePages(let f): move(to: clamp(Int64(cursor) + Int64(f * Double(visibleRows)) * Int64(w)), extend: visual)
            case .rowStart: move(to: cursor - cursor % w, extend: visual)
            case .rowEnd: move(to: min(document.count, cursor - cursor % w + w - 1), extend: visual)
            case .top: move(to: 0, extend: visual)
            case .bottom: move(to: document.count, extend: visual)
            case .enterInsert(let after):
                model.insertMode = true
                move(to: after ? min(document.count, cursor + 1) : cursor, extend: false)
            case .enterReplace: model.insertMode = false
            case .enterNormal: model.insertMode = false; lowNibble = false
            case .startVisual: anchor = cursor; changed()
            case .endVisual: anchor = nil; changed()
            case .yank(let n):
                if n > 0, cursor < document.count {
                    let saved = anchor
                    anchor = cursor
                    let c = cursor
                    cursor = min(document.count, cursor + UInt64(n)) - 1
                    copy(nil)
                    cursor = c
                    anchor = saved
                } else {
                    copy(nil)
                }
            case .paste(let after):
                let wasInsert = model.insertMode
                model.insertMode = true  // p/P insert, like vim
                if after, cursor < document.count { move(to: cursor + 1, extend: false) }
                paste(nil)
                model.insertMode = wasInsert
            case .delete(let n):
                if n > 0, cursor < document.count {
                    // Select n bytes from the cursor, then delete them.
                    anchor = cursor
                    cursor = min(document.count, cursor + UInt64(n)) - 1
                }
                deleteSelectionOrByte()
            case .replaceByte(let b):
                guard !document.isReadOnly, cursor < document.count else { NSSound.beep(); continue }
                edit { try document.overwrite(at: cursor, with: Data([b])) }
                changed(content: true)
            case .undo: undo(nil)
            case .redo: redo(nil)
            case .search: NSApp.sendAction(#selector(DocumentWindowController.showFind(_:)), to: nil, from: self)
            case .searchNext: model.nextHit()
            case .searchPrevious: model.previousHit()
            case .goToPrompt: NSApp.sendAction(#selector(DocumentWindowController.goToOffset(_:)), to: nil, from: self)
            case .setMark(let c):
                let name = String(c)
                model.bookmarks.removeAll { $0.name == name }
                let range = selection ?? cursor ..< min(document.count, cursor + 1)
                model.bookmarks.append(
                    .init(
                        name: name, range: range,
                        color: DocumentModel.bookmarkColors[model.bookmarks.count % DocumentModel.bookmarkColors.count]))
                model.bookmarks.sort { $0.range.lowerBound < $1.range.lowerBound }
            case .jumpMark(let c):
                if let b = model.bookmarks.first(where: { $0.name == String(c) }) {
                    move(to: b.range.lowerBound, extend: visual)
                } else {
                    NSSound.beep()
                }
            case .switchPane: pane = pane == .hex ? .text : .hex; changed()
            case .beep: NSSound.beep()
            }
        }
        model.vimStatusChanged()
    }
}

extension String {
    func leftPad(_ n: Int, _ c: Character = "0") -> String {
        count >= n ? self : String(repeating: c, count: n - count) + self
    }
}
