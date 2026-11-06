import AppKit
import Combine
import HexwerkCore
import SwiftUI

/// One window per open file: toolbar, find bar, hex view, status bar and an
/// inspector sidebar that can be toggled like in Xcode or the Finder.
final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, NSToolbarItemValidation, NSToolbarDelegate {
    let model: DocumentModel
    let hexView: HexView
    private let split = NSSplitViewController()
    private let findHost: NSHostingView<FindBar>
    private var subs: Set<AnyCancellable> = []
    var onClose: ((DocumentWindowController) -> Void)?

    var file: HexwerkCore.Document { model.doc }
    /// The file the user opened (the HEX file for imports, not the image).
    var displayURL: URL { model.importInfo?.source ?? file.url }

    init(file: HexwerkCore.Document) {
        model = DocumentModel(doc: file)
        hexView = HexView(model: model)
        findHost = NSHostingView(rootView: FindBar(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "hexwerk.document"
        window.toolbarStyle = .unified
        super.init(window: window)
        window.delegate = self
        buildContent(in: window)
        buildToolbar(in: window)

        model.jump = { [weak self] offset, range in self?.hexView.jump(to: offset, select: range) }
        model.runScript = { [weak self] in self?.runScript(nil) }
        model.reloadView = { [weak self] in self?.hexView.reload() }
        // Any model change (hits, bookmarks, view options …) may change the grid.
        model.objectWillChange
            .sink { [weak self] in DispatchQueue.main.async { self?.refresh() } }
            .store(in: &subs)
        // The structure model publishes separately (tree, colors, selection).
        model.structure.objectWillChange
            .sink { [weak self] in DispatchQueue.main.async { self?.hexView.needsDisplay = true } }
            .store(in: &subs)
        NotificationCenter.default.publisher(for: .hexwerkVimChanged)
            .sink { [weak self] _ in
                guard let self else { return }
                model.vimEnabled = Settings.shared.bool(forKey: "vimMode")
                model.vim = VimMachine()
                model.vimStatusChanged()
            }
            .store(in: &subs)
        model.yara.objectWillChange
            .sink { [weak self] in DispatchQueue.main.async { self?.hexView.needsDisplay = true } }
            .store(in: &subs)
        model.structure.autoDetect(for: file.url, snapshot: file.snapshot())
        model.analysis.detectType(file.snapshot())
        model.$findVisible
            .sink { [weak self] visible in self?.findHost.isHidden = !visible }
            .store(in: &subs)

        refresh()
        window.setFrameAutosaveName("hexwerk.document")
        window.makeFirstResponder(hexView)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildContent(in window: NSWindow) {
        let status = NSHostingView(rootView: StatusBar(model: model, structure: model.structure, yara: model.yara, analysis: model.analysis))
        findHost.isHidden = true
        let stack = NSStackView(views: [findHost, hexView, status])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.distribution = .fill
        stack.alignment = .width
        hexView.setContentHuggingPriority(.defaultLow, for: .vertical)
        hexView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        status.setContentHuggingPriority(.required, for: .vertical)
        findHost.setContentHuggingPriority(.required, for: .vertical)

        // NSHostingView reports its SwiftUI ideal width; pin bars to full width.
        for v in [findHost, status] as [NSView] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        // The window uses a full-size content view (the inspector reaches up
        // under the toolbar); the grid itself must start below the toolbar.
        let container = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        let main = NSViewController()
        main.view = container
        let mainItem = NSSplitViewItem(viewController: main)
        mainItem.minimumThickness = 480

        let side = NSHostingController(rootView: Sidebar(model: model))
        let sideItem = NSSplitViewItem(inspectorWithViewController: side)
        sideItem.minimumThickness = 280
        sideItem.maximumThickness = 640

        split.addSplitViewItem(mainItem)
        split.addSplitViewItem(sideItem)
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1180, height: 720))
    }

    // MARK: Toolbar

    private enum Item {
        static let open = NSToolbarItem.Identifier("open")
        static let save = NSToolbarItem.Identifier("save")
        static let undo = NSToolbarItem.Identifier("undo")
        static let redo = NSToolbarItem.Identifier("redo")
        static let cut = NSToolbarItem.Identifier("cut")
        static let copy = NSToolbarItem.Identifier("copy")
        static let paste = NSToolbarItem.Identifier("paste")
        static let find = NSToolbarItem.Identifier("find")
        static let goTo = NSToolbarItem.Identifier("goto")
        static let bookmark = NSToolbarItem.Identifier("bookmark")
        static let compare = NSToolbarItem.Identifier("compare")
        static let fill = NSToolbarItem.Identifier("fill")
        static let mode = NSToolbarItem.Identifier("mode")
    }

    private func buildToolbar(in window: NSWindow) {
        let tb = NSToolbar(identifier: "hexwerk.toolbar.v2")
        tb.delegate = self
        tb.displayMode = .iconOnly
        tb.allowsUserCustomization = true
        tb.autosavesConfiguration = true
        window.toolbar = tb
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Item.open, Item.save, .space, Item.undo, Item.redo, .space, Item.cut, Item.copy, Item.paste,
         .space, Item.find, Item.goTo, Item.bookmark, .flexibleSpace, Item.mode,
         .inspectorTrackingSeparator, .flexibleSpace, .toggleInspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Item.open, Item.save, Item.undo, Item.redo, Item.cut, Item.copy, Item.paste, Item.find, Item.goTo,
         Item.bookmark, Item.compare, Item.fill, Item.mode,
         .space, .flexibleSpace, .inspectorTrackingSeparator, .toggleInspector]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case Item.open: button(id, L("Open"), "folder", #selector(tbOpen(_:)), L("Open File (⌘O)"))
        case Item.save: button(id, L("Save"), "square.and.arrow.down", #selector(saveDocument(_:)), L("Save (⌘S)"))
        case Item.undo: button(id, L("Undo"), "arrow.uturn.backward", #selector(tbUndo(_:)), L("Undo (⌘Z)"))
        case Item.redo: button(id, L("Redo"), "arrow.uturn.forward", #selector(tbRedo(_:)), L("Redo (⇧⌘Z)"))
        case Item.cut: button(id, L("Cut"), "scissors", #selector(tbCut(_:)), L("Cut (⌘X)"))
        case Item.copy: button(id, L("Copy"), "doc.on.doc", #selector(tbCopy(_:)), L("Copy (⌘C)"))
        case Item.paste: button(id, L("Paste"), "doc.on.clipboard", #selector(tbPaste(_:)), L("Paste (⌘V)"))
        case Item.find: button(id, L("Find"), "magnifyingglass", #selector(showFind(_:)), L("Find (⌘F)"))
        case Item.goTo: button(id, L("Go To"), "arrow.right.to.line", #selector(goToOffset(_:)), L("Go to Offset (⌘L)"))
        case Item.bookmark: button(id, L("Bookmark"), "bookmark", #selector(addBookmark(_:)), L("Add Bookmark (⌘D)"))
        case Item.compare: button(id, L("Compare"), "arrow.left.arrow.right", #selector(compareWithFile(_:)), L("Compare with File"))
        case Item.fill: button(id, L("Fill"), "rectangle.and.pencil.and.ellipsis", #selector(fillSelection(_:)), L("Fill Selection"))
        case Item.mode: modeItem(id)
        default: nil
        }
    }

    private func modeItem(_ id: NSToolbarItem.Identifier) -> NSToolbarItem {
        let seg = NSSegmentedControl(labels: [L("Overwrite"), L("Insert")], trackingMode: .selectOne,
                                     target: self, action: #selector(modeChanged(_:)))
        seg.selectedSegment = model.insertMode ? 1 : 0
        let item = NSToolbarItem(itemIdentifier: id)
        item.view = seg
        item.label = L("Mode")
        item.paletteLabel = L("Overwrite/Insert")
        item.toolTip = L("Overwrite or Insert (⌘I)")
        return item
    }

    private func button(_ id: NSToolbarItem.Identifier, _ label: String, _ symbol: String,
                        _ action: Selector, _ tip: String) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.label = label
        item.paletteLabel = label
        item.toolTip = tip
        item.target = self
        item.action = action
        item.isBordered = true
        return item
    }

    // Toolbar buttons target the controller; edits go to the hex view, which
    // need not be first responder (e.g. after clicking in the sidebar).
    @objc private func tbOpen(_ sender: Any?) { NSApp.sendAction(#selector(AppDelegate.openDocument(_:)), to: nil, from: sender) }
    @objc private func tbUndo(_ sender: Any?) { hexView.undo(sender) }
    @objc private func tbRedo(_ sender: Any?) { hexView.redo(sender) }
    @objc private func tbCut(_ sender: Any?) { hexView.cut(sender) }
    @objc private func tbCopy(_ sender: Any?) { hexView.copy(sender) }
    @objc private func tbPaste(_ sender: Any?) { hexView.paste(sender) }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        let ro = file.isReadOnly
        switch item.itemIdentifier {
        case Item.save: return !ro && file.isModified
        case Item.undo: return file.canUndo
        case Item.redo: return file.canRedo
        case Item.cut: return hexView.selection != nil && !ro
        case Item.copy: return file.count > 0
        case Item.paste: return !ro && NSPasteboard.general.string(forType: .string) != nil
        case Item.fill: return hexView.selection != nil && !ro
        default: return true
        }
    }

    /// Opens the inspector on the structure tab (status bar format menu).
    @objc func showStructure(_ sender: Any?) { showTab(.structure) }
    @objc func showYara(_ sender: Any?) { showTab(.yara) }

    /// ⇧⌘Y: shows the YARA tab and scans (asks for rules if there are none).
    @objc func scanYara(_ sender: Any?) {
        showTab(.yara)
        guard !model.yara.ruleFiles.isEmpty else { return }
        model.yara.scan(file.snapshot(), selection: hexView.selection)
    }

    /// ⌘R: runs the script of the script tab on this document.
    @objc func runScript(_ sender: Any?) {
        showTab(.script)
        model.script.run(on: file, cursor: hexView.cursor, selection: hexView.selection) { [weak self] changed, r in
            guard let self else { return }
            if changed { hexView.reload() }
            if let s = r.select { hexView.jump(to: s.lowerBound, select: s) }
            else if let g = r.goTo { hexView.jump(to: g, select: nil) }
            refresh()
        }
    }

    @objc func showAnalysis(_ sender: Any?) { showTab(.analysis) }

    // MARK: Calculator support

    /// pos, sel, size and the integers under the cursor (current endianness).
    func calculatorVariables() -> [String: UInt64] {
        let c = hexView.cursor
        var vars: [String: UInt64] = ["pos": c + model.offsetBase, "size": file.count,
                                      "sel": UInt64(hexView.selection?.count ?? 0)]
        let bytes = file.read(c ..< c + 8)
        for (name, n) in [("u8", 1), ("u16", 2), ("u32", 4), ("u64", 8)] where bytes.count >= n {
            let slice = Array(bytes.prefix(n))
            vars[name] = (model.endian == .little ? slice.reversed() : slice).reduce(0) { $0 << 8 | UInt64($1) }
        }
        return vars
    }

    /// Calculator "go to": the value is an address when the file has a load address.
    func goToValue(_ v: UInt64) {
        guard v >= model.offsetBase, v - model.offsetBase <= file.count else { NSSound.beep(); return }
        hexView.jump(to: v - model.offsetBase, select: nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func showTab(_ tab: DocumentModel.SidebarTab) {
        model.sidebarTab = tab
        if let side = split.splitViewItems.last, side.isCollapsed { side.animator().isCollapsed = false }
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        model.insertMode = sender.selectedSegment == 1
    }

    /// Title, subtitle, edited dot, toolbar state and the grid after any change.
    func refreshTitle() { refresh() }

    private func refresh() {
        guard let window else { return }
        window.title = displayURL.lastPathComponent
        var sub = [ByteCountFormatter.string(fromByteCount: Int64(file.count), countStyle: .binary)]
        if let i = model.importInfo { sub.append(L("%1$@ at %2$@", i.format.rawValue, hex(model.offsetBase))) }
        if file.isReadOnly { sub.append(L("read-only")) }
        if file.isModified { sub.append(L("modified")) }
        window.subtitle = sub.joined(separator: " · ")
        window.representedURL = displayURL
        window.isDocumentEdited = file.isModified
        if let seg = window.toolbar?.items.first(where: { $0.itemIdentifier == Item.mode })?.view as? NSSegmentedControl {
            seg.selectedSegment = model.insertMode ? 1 : 0
            seg.isEnabled = !file.isReadOnly
        }
        hexView.needsDisplay = true
    }

    // MARK: Actions

    @objc func toggleInsertMode(_ sender: Any?) { model.insertMode.toggle() }

    @objc func showFind(_ sender: Any?) {
        model.findVisible = true
        if let sel = hexView.selection, sel.count <= 64, model.findText.isEmpty {
            model.findMode = .hex
            model.findText = file.read(sel).map { String(format: "%02X", $0) }.joined(separator: " ")
        }
    }

    @objc func findNext(_ sender: Any?) { model.nextHit() }
    @objc func findPrevious(_ sender: Any?) { model.previousHit() }
    @objc func nextDifference(_ sender: Any?) { model.jumpToDiff(forward: true) }
    @objc func previousDifference(_ sender: Any?) { model.jumpToDiff(forward: false) }

    @objc func goToOffset(_ sender: Any?) {
        prompt(title: L("Go to Offset"),
               message: model.offsetBase != 0
                   ? L("Address in decimal or hex (0x…), from %@. + or − for relative.", hex(model.offsetBase))
                   : L("Decimal or hex (0x…). + or − relative to the current position."),
               placeholder: "0x1000", text: "",
               validate: { [unowned self] in parseOffset($0) != nil }) { [self] text in
            guard let text, let target = parseOffset(text) else { return }
            hexView.jump(to: target, select: nil)
            window?.makeFirstResponder(hexView)
        }
    }

    /// "0x10", "16", "+0x10", "-8" → absolute offset within the file.
    func parseOffset(_ text: String) -> UInt64? {
        var s = text.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "_", with: "")
        var sign = 0
        if s.hasPrefix("+") { sign = 1; s.removeFirst() } else if s.hasPrefix("-") || s.hasPrefix("−") { sign = -1; s.removeFirst() }
        let v = s.hasPrefix("0x") ? UInt64(s.dropFirst(2), radix: 16) : UInt64(s)
        guard let v else { return nil }
        let c = hexView.cursor
        // Absolute values are addresses when the file has a load address.
        if sign == 0, v < model.offsetBase { return nil }
        let target: UInt64 = switch sign {
        case 1: c.addingReportingOverflow(v).overflow ? .max : c + v
        case -1: c >= v ? c - v : 0
        default: v - model.offsetBase
        }
        return target <= file.count ? target : nil
    }

    @objc func addBookmark(_ sender: Any?) {
        prompt(title: L("Add Bookmark"),
               message: hexView.selection.map { L("Selection: %1$ld bytes at %2$@", $0.count, hex($0.lowerBound)) }
                   ?? L("Position %@", hex(hexView.cursor)),
               placeholder: L("Name"), text: "", validate: { _ in true }) { [self] name in
            guard let name else { return }
            model.addBookmark(name: name)
        }
    }

    @objc func fillSelection(_ sender: Any?) {
        guard hexView.selection != nil else { NSSound.beep(); return }
        prompt(title: L("Fill Selection"), message: L("Hex pattern, repeated over the selection."),
               placeholder: L("00 or DE AD BE EF"), text: "00",
               validate: { Self.fixedBytes($0) != nil }) { [self] text in
            guard let text, let bytes = Self.fixedBytes(text) else { return }
            hexView.fillSelection(with: bytes)
        }
    }

    static func fixedBytes(_ text: String) -> Data? {
        guard let p = SearchPattern.hex(text) else { return nil }
        let b = p.elements.compactMap { if case .byte(let v) = $0 { v } else { nil } }
        return b.count == p.count ? Data(b) : nil
    }

    @objc func compareWithFile(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.message = L("Choose a file to compare with %@", file.url.lastPathComponent)
        panel.beginSheetModal(for: window) { [self] response in
            guard response == .OK, let url = panel.url else { return }
            model.compare(with: url)
        }
    }

    @objc func setBytesPerRow(_ sender: NSMenuItem) { model.bytesPerRowSetting = sender.tag }
    @objc func toggleDecimalOffsets(_ sender: Any?) { model.decimalOffsets.toggle() }

    /// App-wide setting; every open window follows.
    @objc func toggleVim(_ sender: Any?) {
        let on = !model.vimEnabled
        Settings.shared.set(on, forKey: "vimMode")
        NotificationCenter.default.post(name: .hexwerkVimChanged, object: nil)
    }
    @objc func setCharset(_ sender: NSMenuItem) { model.charset = TextEncodingView.allCases[sender.tag] }

    private func prompt(title: String, message: String, placeholder: String, text: String,
                        validate: @escaping (String) -> Bool, done: @escaping (String?) -> Void) {
        guard let window else { return }
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        let view = PromptSheet(title: title, message: message, placeholder: placeholder, input: PromptText(text),
                               validate: validate) { [weak window, weak sheet] result in
            if let sheet { window?.endSheet(sheet) }
            done(result)
        }
        sheet.contentViewController = NSHostingController(rootView: view)
        window.beginSheet(sheet)
    }

    // MARK: Export (FR-9.4)

    /// Selection, or the whole file if nothing is selected.
    private var exportRange: Range<UInt64> { hexView.selection ?? 0 ..< file.count }

    @objc func copyAs(_ sender: NSMenuItem) {
        let format = ExportFormat.allCases[sender.tag]
        let r = exportRange
        // Text renderings grow 4–6×; beyond a few MB the clipboard is the wrong tool.
        guard r.count <= 4 << 20 else {
            let a = NSAlert()
            a.messageText = L("Selection too large to copy (%@).", ByteCountFormatter.string(fromByteCount: Int64(r.count), countStyle: .binary))
            a.informativeText = L("At most 4 MiB. Save larger ranges with File → Export Selection.")
            a.runModal()
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(format.render(file.read(r)), forType: .string)
    }

    @objc func exportSelection(_ sender: Any?) {
        guard let window else { return }
        let r = exportRange
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.url.deletingPathExtension().lastPathComponent
            + "_\(String(r.lowerBound, radix: 16, uppercase: true))-\(String(r.upperBound, radix: 16, uppercase: true)).bin"
        panel.message = L("Save %1$ld bytes at %2$@ as raw data", r.count, hex(r.lowerBound))
        panel.beginSheetModal(for: window) { [self] response in
            guard response == .OK, let url = panel.url else { return }
            do { try file.read(r).write(to: url, options: .atomic) } catch { showError(error) }
        }
    }

    // MARK: Saving

    @objc func saveDocument(_ sender: Any?) { _ = save() }

    /// Returns false if saving failed or was cancelled.
    private func save() -> Bool {
        if file.hasChangedOnDisk() {
            let a = NSAlert()
            a.messageText = L("%@ was changed outside hexwerk.", file.url.lastPathComponent)
            a.informativeText = L("Saving discards those changes.")
            a.addButton(withTitle: L("Save Anyway"))
            a.addButton(withTitle: L("Cancel"))
            guard a.runModal() == .alertFirstButtonReturn else { return false }
        }
        do {
            try file.save()
            if let i = model.importInfo { try writeBack(i) }
            hexView.reload()
            return true
        } catch {
            showError(error)
            return false
        }
    }

    /// Writes the image back as Intel HEX / S-Record, keeping untouched gaps.
    private func writeBack(_ i: DocumentModel.ImportInfo) throws {
        let data = file.read(0 ..< file.count)
        let segs = HexRecords.segments(data, base: model.offsetBase, gaps: i.gaps)
        let text = i.format == .intelHex
            ? HexRecords.intelHex(segs, start: i.start)
            : HexRecords.srec(segs, start: i.start, header: i.header ?? "hexwerk")
        try text.write(to: i.source, atomically: true, encoding: .ascii)
    }

    @objc func exportHexRecords(_ sender: NSMenuItem) {
        guard let window else { return }
        let format = HexRecords.Format.allCases[sender.tag]
        let r = exportRange
        let panel = NSSavePanel()
        panel.nameFieldStringValue = displayURL.deletingPathExtension().lastPathComponent + "." + format.fileExtension
        panel.message = L("%1$ld bytes as %2$@, address from %3$@", r.count, format.rawValue, hex(model.offsetBase + r.lowerBound))
        panel.beginSheetModal(for: window) { [self] response in
            guard response == .OK, let url = panel.url else { return }
            let data = file.read(r), base = model.offsetBase + r.lowerBound
            let text = format == .intelHex ? HexRecords.intelHex(data, base: base) : HexRecords.srec(data, base: base)
            do { try text.write(to: url, atomically: true, encoding: .ascii) } catch { showError(error) }
        }
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        guard let window else { return }
        let panel = NSSavePanel()
        // For imports, file.url is the cache image that is deleted on close.
        panel.nameFieldStringValue = displayURL.lastPathComponent
        panel.directoryURL = displayURL.deletingLastPathComponent()
        if model.importInfo != nil {
            panel.message = L("Ending .hex or .srec: save as Intel HEX or S-Record; any other ending: save the raw bytes")
        }
        panel.beginSheetModal(for: window) { [self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                if let i = model.importInfo { try saveImport(i, as: url) } else { try file.save(as: url) }
                hexView.reload()
                refresh()
            } catch {
                showError(error)
            }
        }
    }

    /// Save As for an imported file: a HEX/S-Record ending makes `url` the new
    /// write-back target, any other ending turns the window into a plain
    /// binary document at `url` (off the import cache).
    private func saveImport(_ i: DocumentModel.ImportInfo, as url: URL) throws {
        if let format = HexRecords.Format(fileExtension: url.pathExtension) {
            let target = DocumentModel.ImportInfo(source: url, format: format, gaps: i.gaps, start: i.start, header: i.header)
            try writeBack(target)
            model.importInfo = target
            try file.save()
        } else {
            try file.save(as: url)
            model.importInfo = nil
        }
    }

    private func showError(_ error: Error) {
        let a = NSAlert()
        a.messageText = L("Error")
        a.informativeText = String(describing: error)
        a.runModal()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(saveDocument(_:)): return !file.isReadOnly && file.isModified
        case #selector(toggleInsertMode(_:)):
            item.state = model.insertMode ? .on : .off
            return !file.isReadOnly
        case #selector(findNext(_:)), #selector(findPrevious(_:)): return !model.findText.isEmpty
        case #selector(nextDifference(_:)), #selector(previousDifference(_:)): return !model.diffs.isEmpty
        case #selector(fillSelection(_:)): return hexView.selection != nil && !file.isReadOnly
        case #selector(copyAs(_:)), #selector(exportSelection(_:)), #selector(exportHexRecords(_:)): return file.count > 0
        case #selector(setBytesPerRow(_:)):
            item.state = model.bytesPerRowSetting == item.tag ? .on : .off
            return true
        case #selector(toggleVim(_:)):
            item.state = model.vimEnabled ? .on : .off
            return true
        case #selector(toggleDecimalOffsets(_:)):
            item.state = model.decimalOffsets ? .on : .off
            return true
        case #selector(setCharset(_:)):
            item.state = TextEncodingView.allCases[item.tag] == model.charset ? .on : .off
            return true
        default: return true
        }
    }

    // MARK: Closing

    /// Asks about unsaved changes. Returns true if the window may close.
    func confirmClose() -> Bool {
        guard file.isModified else { return true }
        let a = NSAlert()
        a.messageText = L("Save changes to %@?", file.url.lastPathComponent)
        a.informativeText = L("Your changes will be lost if you don't save them.")
        a.addButton(withTitle: L("Save"))
        a.addButton(withTitle: L("Cancel"))
        a.addButton(withTitle: L("Don't Save"))
        switch a.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { confirmClose() }

    // MARK: Project state (FR-10.7)

    func projectState() -> ProjectState {
        var s = ProjectState(filePath: displayURL.standardizedFileURL.path, fileSize: file.count)
        s.bookmarks = model.bookmarks.map {
            .init(name: $0.name, start: $0.range.lowerBound, end: $0.range.upperBound,
                  color: DocumentModel.bookmarkColors.firstIndex(of: $0.color) ?? 0)
        }
        if let u = model.structure.formatURL { s.format = .init(path: u.path, title: model.structure.formatTitle ?? u.lastPathComponent) }
        s.yaraRules = model.yara.ruleFiles.map(\.path)
        s.cursor = hexView.cursor
        s.selectionStart = hexView.selection?.lowerBound
        s.selectionEnd = hexView.selection?.upperBound
        s.offsetBase = model.offsetBase
        return s
    }

    /// Applies a remembered or imported state; offsets past the end are dropped.
    func apply(_ s: ProjectState) {
        let n = file.count
        model.bookmarks = s.bookmarks.filter { $0.start < n }.map {
            DocumentModel.Bookmark(name: $0.name, range: $0.start ..< min(n, max($0.start + 1, $0.end)),
                                   color: DocumentModel.bookmarkColors[$0.color % DocumentModel.bookmarkColors.count])
        }
        if let f = s.format, FileManager.default.fileExists(atPath: f.path) {
            model.structure.apply(URL(fileURLWithPath: f.path), title: f.title, snapshot: file.snapshot())
        }
        let rules = s.yaraRules.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !rules.isEmpty { model.yara.ruleFiles = rules }
        if model.importInfo == nil, s.offsetBase != 0 { model.offsetBase = s.offsetBase }
        if let a = s.selectionStart, let b = s.selectionEnd, a < b, b <= n {
            hexView.jump(to: a, select: a ..< b)
        } else {
            hexView.jump(to: min(s.cursor, n), select: nil)
        }
        refresh()
    }

    func restoreProject() {
        if let s = ProjectStore.load(for: displayURL) { apply(s) }
    }

    func saveProject() {
        try? ProjectStore.save(projectState(), for: displayURL)
    }

    @objc func exportProject(_ sender: Any?) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ProjectStore.sidecar(for: displayURL).lastPathComponent
        panel.directoryURL = displayURL.deletingLastPathComponent()
        panel.message = L("Save bookmarks, format, YARA rules and position as a project file")
        panel.beginSheetModal(for: window) { [self] response in
            guard response == .OK, let url = panel.url else { return }
            do { try ProjectStore.write(projectState(), to: url) } catch { showError(error) }
        }
    }

    func windowWillClose(_ notification: Notification) {
        saveProject()
        model.cancelSearch()
        onClose?(self)
    }
}

extension Notification.Name {
    static let hexwerkVimChanged = Notification.Name("hexwerkVimChanged")
}
