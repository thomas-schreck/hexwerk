import AppKit
import Combine
import HexwerkCore
import SwiftUI

/// One window per open file: toolbar, find bar, hex view, status bar and an
/// inspector sidebar that can be toggled like in Xcode or the Finder.
final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, NSToolbarItemValidation, NSToolbarDelegate
{
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
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "hexwerk.document"
        window.toolbarStyle = .unified
        // Tab out of the grid reaches the find bar and the sidebar controls.
        window.autorecalculatesKeyViewLoop = true
        super.init(window: window)
        window.delegate = self
        buildContent(in: window)
        buildToolbar(in: window)

        model.jump = { [weak self] offset, range in self?.hexView.jump(to: offset, select: range) }
        model.runScript = { [weak self] in self?.runScript(nil) }
        model.reloadView = { [weak self] in self?.hexView.reload() }
        // Any model change (hits, bookmarks, view options …) may change the grid.
        // Coalesced: a burst of changes (cursor, inspector, progress) costs one refresh.
        model.objectWillChange
            .sink { [weak self] in self?.scheduleRefresh() }
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
        model.rules.objectWillChange
            .sink { [weak self] in DispatchQueue.main.async { self?.hexView.needsDisplay = true } }
            .store(in: &subs)
        model.structure.autoDetect(for: file.url, snapshot: file.snapshot())
        model.analysis.detectType(file.snapshot())
        model.$findVisible
            .sink { [weak self] visible in self?.findHost.isHidden = !visible }
            .store(in: &subs)

        if !file.isReadOnly {
            recovery = RecoveryAutosave(store: .user, url: file.url) { [weak self] status in
                Task { @MainActor in self?.recoveryStatusChanged(status) }
            }
        }
        recoveryEditState = file.editState
        refresh()
        watchFile()
        window.setFrameAutosaveName("hexwerk.document")
        window.makeFirstResponder(hexView)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildContent(in window: NSWindow) {
        let status = NSHostingView(
            rootView: StatusBar(model: model, structure: model.structure, yara: model.yara, analysis: model.analysis))
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
        [
            Item.open, Item.save, .space, Item.undo, Item.redo, .space, Item.cut, Item.copy, Item.paste,
            .space, Item.find, Item.goTo, Item.bookmark, .flexibleSpace, Item.mode,
            .inspectorTrackingSeparator, .flexibleSpace, .toggleInspector,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            Item.open, Item.save, Item.undo, Item.redo, Item.cut, Item.copy, Item.paste, Item.find, Item.goTo,
            Item.bookmark, Item.compare, Item.fill, Item.mode,
            .space, .flexibleSpace, .inspectorTrackingSeparator, .toggleInspector,
        ]
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
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
        let seg = NSSegmentedControl(
            labels: [L("Overwrite"), L("Insert")], trackingMode: .selectOne,
            target: self, action: #selector(modeChanged(_:)))
        seg.selectedSegment = model.insertMode ? 1 : 0
        let item = NSToolbarItem(itemIdentifier: id)
        item.view = seg
        item.label = L("Mode")
        item.paletteLabel = L("Overwrite/Insert")
        item.toolTip = L("Overwrite or Insert (⌘I)")
        return item
    }

    private func button(
        _ id: NSToolbarItem.Identifier, _ label: String, _ symbol: String,
        _ action: Selector, _ tip: String
    ) -> NSToolbarItem {
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
        guard !model.script.running else { return }
        model.scriptHighlights = []
        model.script.run(on: file, cursor: hexView.cursor, selection: hexView.selection, baseAddress: model.offsetBase) {
            [weak self] changed, r in
            guard let self else { return }
            if changed { hexView.reload() }
            model.applyScriptAnnotations(r.annotations)
            if let s = r.select { hexView.jump(to: s.lowerBound, select: s) } else if let g = r.goTo { hexView.jump(to: g, select: nil) }
            refresh()
        }
    }

    @objc func showAnalysis(_ sender: Any?) { showTab(.analysis) }

    // MARK: Calculator support

    /// pos, sel, size and the integers under the cursor (current endianness).
    func calculatorVariables() -> [String: UInt64] {
        let c = hexView.cursor
        var vars: [String: UInt64] = [
            "pos": model.addresses.address(of: c), "size": file.count,
            "sel": UInt64(hexView.selection?.count ?? 0),
        ]
        let bytes = file.read(c ..< c + 8)
        for (name, n) in [("u8", 1), ("u16", 2), ("u32", 4), ("u64", 8)] where bytes.count >= n {
            let slice = Array(bytes.prefix(n))
            vars[name] = (model.endian == .little ? slice.reversed() : slice).reduce(0) { $0 << 8 | UInt64($1) }
        }
        return vars
    }

    /// Calculator "go to": the value is an address when the file has a load address.
    func goToValue(_ v: UInt64) {
        guard let o = model.addresses.offset(of: v, count: file.count) else { NSSound.beep(); return }
        hexView.jump(to: o, select: nil)
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

    private var refreshPending = false

    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshPending = false
            self?.refresh()
        }
    }

    private func refresh() {
        guard let window else { return }
        updateRecovery()
        let modified = file.isModified
        var sub = [ByteCountFormatter.string(fromByteCount: Int64(file.count), countStyle: .binary)]
        if let i = model.importInfo { sub.append(L("%1$@ at %2$@", i.format.rawValue, hex(i.base))) }
        if file.isReadOnly { sub.append(L("read-only")) }
        if modified { sub.append(L("modified")) }
        if modified, activeRecovery != nil {
            switch recoveryStatus {
            case .tooLarge: sub.append(L("too large for auto-recovery"))
            case .failed: sub.append(L("auto-recovery failed"))
            default: break
            }
        }
        let subtitle = sub.joined(separator: " · ")
        // Setting these always invalidates the title bar (and the proxy icon).
        if window.title != displayURL.lastPathComponent { window.title = displayURL.lastPathComponent }
        if window.subtitle != subtitle { window.subtitle = subtitle }
        if window.representedURL != displayURL { window.representedURL = displayURL }
        if window.isDocumentEdited != modified { window.isDocumentEdited = modified }
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

    // Navigation and selection helpers (#140)
    @objc func goBack(_ sender: Any?) { hexView.goBack() }
    @objc func goForward(_ sender: Any?) { hexView.goBack(forward: true) }
    @objc func selectParentStructure(_ sender: Any?) { hexView.selectParentStructure() }
    @objc func selectNextRecord(_ sender: Any?) { hexView.stepSelection(forward: true) }
    @objc func selectPreviousRecord(_ sender: Any?) { hexView.stepSelection(forward: false) }
    @objc func markSelectionStart(_ sender: Any?) { hexView.markSelectionStart() }
    @objc func markSelectionEnd(_ sender: Any?) { hexView.markSelectionEnd() }

    @objc func goToOffset(_ sender: Any?) {
        prompt(
            title: L("Go to Offset"),
            message: model.offsetBase != 0
                ? L("Address in decimal or hex (0x…), from %@. + or − for relative.", hex(model.offsetBase))
                : L("Decimal or hex (0x…). + or − relative to the current position."),
            placeholder: "0x1000", text: "",
            validate: { [unowned self] in parseOffset($0) != nil }
        ) { [self] text in
            guard let text, let target = parseOffset(text) else { return }
            hexView.jump(to: target, select: nil)
            window?.makeFirstResponder(hexView)
        }
    }

    /// "0x10", "16", "+0x10", "-8" → absolute offset within the file.
    func parseOffset(_ text: String) -> UInt64? {
        // Absolute values are addresses when the file has a base address.
        model.addresses.target(of: text, cursor: hexView.cursor, count: file.count)
    }

    /// View → Base Address…: the address of offset 0, for display and
    /// navigation only (#143). 0 switches back to plain offsets.
    @objc func setBaseAddress(_ sender: Any?) {
        prompt(
            title: L("Base Address"),
            message: L("Address of the first byte, decimal or hex (0x…). Only the display changes, not the file."),
            placeholder: "0x08000000", text: model.offsetBase == 0 ? "" : hex(model.offsetBase),
            validate: { [unowned self] in
                $0.trimmingCharacters(in: .whitespaces).isEmpty
                    || AddressMap.parseNumber($0).map { AddressMap.isValid(base: $0, count: file.count) } == true
            }
        ) { [self] text in
            guard let text else { return }
            let t = text.trimmingCharacters(in: .whitespaces)
            guard let base = t.isEmpty ? 0 : AddressMap.parseNumber(t), AddressMap.isValid(base: base, count: file.count) else { return }
            model.offsetBase = base
            refresh()
        }
    }

    @objc func takeDifference(_ sender: Any?) { model.takeOver(all: false) }
    @objc func takeAllDifferences(_ sender: Any?) { model.takeOver(all: true) }

    @objc func addBookmark(_ sender: Any?) {
        prompt(
            title: L("Add Bookmark"),
            message: hexView.selection.map { L("Selection: %1$ld bytes at %2$@", $0.count, hex($0.lowerBound)) }
                ?? L("Position %@", hex(hexView.cursor)),
            placeholder: L("Name"), text: "", validate: { _ in true }
        ) { [self] name in
            guard let name else { return }
            model.addBookmark(name: name)
        }
    }

    @objc func fillSelection(_ sender: Any?) {
        guard let sel = hexView.selection else { NSSound.beep(); return }
        guard confirmFillSize(UInt64(sel.count)) else { return }
        prompt(
            title: L("Fill Selection"), message: L("Hex pattern, repeated over the selection."),
            placeholder: L("00 or DE AD BE EF"), text: "00",
            validate: { Self.fixedBytes($0) != nil }
        ) { [self] text in
            guard let text, let bytes = Self.fixedBytes(text) else { return }
            hexView.fillSelection(with: bytes)
        }
    }

    /// A fill keeps all new bytes in memory until saving: ask for large
    /// selections, refuse ones that would exhaust memory.
    private func confirmFillSize(_ n: UInt64) -> Bool {
        let size = ByteCountFormatter.string(fromByteCount: Int64(clamping: n), countStyle: .binary)
        let a = NSAlert()
        if n > FillPattern.maximum {
            a.messageText = L("Selection too large to fill (%@).", size)
            a.informativeText = L("Filling keeps the new bytes in memory until saving; this would exceed the available memory.")
            a.runModal()
            return false
        }
        guard n > FillPattern.confirmAbove else { return true }
        a.messageText = L("Fill %@?", size)
        a.informativeText = L("The new bytes are kept in memory until the file is saved.")
        a.addButton(withTitle: L("Fill"))
        a.addButton(withTitle: L("Cancel"))
        return a.runModal() == .alertFirstButtonReturn
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

    @objc func showHighlightRules(_ sender: Any?) {
        guard let window else { return }
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        sheet.contentViewController = NSHostingController(
            rootView: HighlightRulesSheet(rules: model.rules) { [weak window, weak sheet] in
                if let sheet { window?.endSheet(sheet) }
            })
        window.beginSheet(sheet)
    }

    private func prompt(
        title: String, message: String, placeholder: String, text: String,
        validate: @escaping (String) -> Bool, done: @escaping (String?) -> Void
    ) {
        guard let window else { return }
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        let view = PromptSheet(
            title: title, message: message, placeholder: placeholder, input: PromptText(text),
            validate: validate
        ) { [weak window, weak sheet] result in
            if let sheet { window?.endSheet(sheet) }
            done(result)
        }
        sheet.contentViewController = NSHostingController(rootView: view)
        window.beginSheet(sheet)
    }

    // MARK: Export

    /// Selection, or the whole file if nothing is selected.
    private var exportRange: Range<UInt64> { hexView.selection ?? 0 ..< file.count }

    @objc func copyAs(_ sender: NSMenuItem) {
        let format = ExportFormat.allCases[sender.tag]
        let r = exportRange
        // Text renderings grow 4–6×; beyond a few MB the clipboard is the wrong tool.
        guard r.count <= 4 << 20 else {
            let a = NSAlert()
            a.messageText = L(
                "Selection too large to copy (%@).", ByteCountFormatter.string(fromByteCount: Int64(r.count), countStyle: .binary))
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
        panel.nameFieldStringValue =
            file.url.deletingPathExtension().lastPathComponent
            + "_\(String(r.lowerBound, radix: 16, uppercase: true))-\(String(r.upperBound, radix: 16, uppercase: true)).bin"
        panel.message = L("Save %1$ld bytes at %2$@ as raw data", r.count, hex(r.lowerBound))
        panel.beginSheetModal(for: window) { [self] response in
            guard response == .OK, let url = panel.url else { return }
            do { try file.read(r).write(to: url, options: .atomic) } catch { showError(error) }
        }
    }

    // MARK: Saving

    @objc func saveDocument(_ sender: Any?) { save { _ in } }

    /// Saves; `done` gets false if saving failed or was cancelled. A large
    /// save runs in the background, so `done` may come later.
    private func save(done: @escaping (Bool) -> Void) {
        guard !isSaving else { return done(false) }
        switch file.diskChange() {
        case .none: break
        case .modified:
            // Never save from a mapping whose file changed underneath.
            checkDisk()
            return done(false)
        case .replaced:
            guard confirmOverwrite(file.url) else { return done(false) }
            file.keepAfterReplace()
        }
        if let i = model.importInfo, let stamp = importStamp, (try? DiskStamp(i.source)) != stamp {
            guard confirmOverwrite(i.source) else { return done(false) }
        }
        do {
            // Write-back first: saving the cache image clears isModified, so a
            // failing write-back afterwards would leave the edits looking saved.
            if let i = model.importInfo {
                try writeBack(i)
                importStamp = try? DiskStamp(i.source)
            }
            guard let job = try file.prepareSave(mode: .automatic) else { return done(true) }
            write(job, done: done)
        } catch {
            showError(error)
            done(false)
        }
    }

    // MARK: Background save (#79)

    /// Smaller saves are written right away, without a progress sheet.
    private static let backgroundSaveMinimum: UInt64 = 32 << 20
    private var saveTask: Task<Void, Never>?
    /// Told when the running save ended (true: saved).
    private var afterSave: [(Bool) -> Void] = []
    var isSaving: Bool { saveTask != nil }

    /// Writes a prepared save. A large one runs off the main thread behind
    /// a progress sheet with Cancel; the sheet also keeps the window from
    /// taking edits, and the document refuses them until the save ends.
    private func write(_ job: SaveJob, done: @escaping (Bool) -> Void) {
        guard job.byteCount >= Self.backgroundSaveMinimum, let window else {
            let result = Result { try job.write() }
            return saveEnded(job, result, done: done)
        }
        let progress = SaveProgress(total: job.byteCount, cancellable: job.isCancellable)
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        sheet.contentViewController = NSHostingController(
            rootView: SaveProgressSheet(
                name: job.target.lastPathComponent, progress: progress
            ) { [weak self] in self?.saveTask?.cancel() })
        window.beginSheet(sheet)
        afterSave.append(done)
        saveTask = Task.detached(priority: .userInitiated) { [weak self] in
            var throttle = ProgressThrottle()
            let result = Result {
                try job.write(
                    progress: { n in
                        guard throttle.shouldReport() else { return }
                        Task { @MainActor in progress.done = n }
                    }, isCancelled: { Task.isCancelled })
            }
            await MainActor.run {
                window.endSheet(sheet)
                guard let self else { return }
                self.saveTask = nil
                let waiting = self.afterSave
                self.afterSave = []
                self.saveEnded(job, result) { ok in waiting.forEach { $0(ok) } }
            }
        }
    }

    private func saveEnded(_ job: SaveJob, _ result: Result<Void, Error>, done: (Bool) -> Void) {
        do {
            try result.get()
            try file.finishSave(job)
        } catch {
            file.abandonSave()
            if !(error is CancellationError) { showError(error) }
            refresh()
            return done(false)
        }
        hexView.reload()
        refresh()
        watchFile()
        done(true)
    }

    private func confirmOverwrite(_ url: URL) -> Bool {
        let a = NSAlert()
        a.messageText = L("%@ was changed by another program.", url.lastPathComponent)
        a.informativeText = L("Saving overwrites the other program's version with yours.")
        a.addButton(withTitle: L("Save Anyway"))
        a.addButton(withTitle: L("Cancel"))
        return a.runModal() == .alertFirstButtonReturn
    }

    // MARK: Changes by other programs (#5)

    /// State of the imported HEX/S-Record file when it was read.
    var importStamp: DiskStamp?
    private var fileWatch: DispatchSourceFileSystemObject?
    private var askingAboutDisk = false

    /// Watches the file at the document's path. Re-armed after every save
    /// and reload, because an atomic save puts a new file there.
    private func watchFile() {
        fileWatch?.cancel()
        fileWatch = nil
        let fd = Darwin.open(file.url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke], queue: .main)
        src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.checkDisk() } }
        src.setCancelHandler { Darwin.close(fd) }
        src.resume()
        fileWatch = src
    }

    func windowDidBecomeKey(_ notification: Notification) { checkDisk() }

    /// Reacts to a change by another program. A file changed in place is
    /// reloaded at once: it can no longer be saved from (see
    /// `Document.DiskChange.modified`). A replaced file leaves the mapping
    /// intact, so the user may keep their version.
    func checkDisk() {
        // A running save changes the file itself; watchFile() re-arms after.
        guard !askingAboutDisk, !isSaving else { return }
        let change = file.diskChange()
        if change == .none { return }
        let name = file.url.lastPathComponent
        let exists = FileManager.default.fileExists(atPath: file.url.path)
        askingAboutDisk = true
        defer { askingAboutDisk = false }

        if change == .modified {
            if file.isModified {
                let a = NSAlert()
                a.messageText = L("%@ was changed by another program.", name)
                a.informativeText = L(
                    "It was modified in place, so the content shown can no longer be trusted or saved. hexwerk reloads it from disk; your unsaved changes are lost."
                )
                a.addButton(withTitle: L("Reload"))
                a.runModal()
            }
            reloadFromDisk()
            return
        }
        // Replaced, moved or deleted.
        if !file.isModified {
            if exists { reloadFromDisk() } else { file.keepAfterReplace() }
            return
        }
        let a = NSAlert()
        a.messageText =
            exists
            ? L("%@ was replaced by another program.", name)
            : L("%@ was moved or deleted by another program.", name)
        a.informativeText = L(
            "Your version with the unsaved changes is still intact. Keep Mine continues editing; saving then overwrites the file on disk.")
        a.addButton(withTitle: L("Keep Mine"))
        a.addButton(withTitle: L("Save As…"))
        if exists { a.addButton(withTitle: L("Reload")) }
        switch a.runModal() {
        case .alertFirstButtonReturn:
            file.keepAfterReplace()
        case .alertSecondButtonReturn:
            file.keepAfterReplace()
            DispatchQueue.main.async { [weak self] in self?.saveDocumentAs(nil) }
        default:
            reloadFromDisk()
        }
    }

    /// Discards the edits and shows the file as it is on disk now.
    private func reloadFromDisk() {
        do { try file.revertToDisk() } catch {
            showError(error)
            return
        }
        hexView.reload()
        refresh()
        watchFile()
    }

    /// Writes the image back as Intel HEX / S-Record, keeping untouched gaps.
    private func writeBack(_ i: DocumentModel.ImportInfo) throws {
        let data = file.read(0 ..< file.count)
        let segs = HexRecords.segments(data, base: i.base, gaps: i.gaps)
        let text =
            i.format == .intelHex
            ? try HexRecords.intelHex(segs, start: i.start, startSegment: i.startSegment)
            : try HexRecords.srec(segs, start: i.start, header: i.header ?? "hexwerk")
        // Not String.write(atomically:): that drops xattrs (quarantine) and
        // breaks hard links.
        try Document.write(Data(text.utf8), to: i.source)
    }

    @objc func exportHexRecords(_ sender: NSMenuItem) {
        guard let window else { return }
        let format = HexRecords.Format.allCases[sender.tag]
        let r = exportRange
        let panel = NSSavePanel()
        panel.nameFieldStringValue = displayURL.deletingPathExtension().lastPathComponent + "." + format.fileExtension
        panel.message = L("%1$ld bytes as %2$@, address from %3$@", r.count, format.rawValue, model.addressText(r.lowerBound))
        panel.beginSheetModal(for: window) { [self] response in
            guard response == .OK, let url = panel.url else { return }
            let data = file.read(r), base = model.addresses.address(of: r.lowerBound)
            do {
                let text = format == .intelHex ? try HexRecords.intelHex(data, base: base) : try HexRecords.srec(data, base: base)
                try text.write(to: url, atomically: true, encoding: .ascii)
            } catch { showError(error) }
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
                if let i = model.importInfo {
                    try saveImport(i, as: url)
                    hexView.reload()
                    refresh()
                    watchFile()
                } else {
                    write(try file.prepareSave(as: url)) { _ in }
                }
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
            let target = DocumentModel.ImportInfo(source: url, format: format, base: i.base, gaps: i.gaps, start: i.start, header: i.header)
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
        case #selector(saveDocument(_:)): return !file.isReadOnly && file.isModified && !isSaving
        case #selector(toggleInsertMode(_:)):
            item.state = model.insertMode ? .on : .off
            return !file.isReadOnly
        case #selector(findNext(_:)), #selector(findPrevious(_:)): return !model.findText.isEmpty
        case #selector(nextDifference(_:)), #selector(previousDifference(_:)): return !model.diffs.isEmpty
        case #selector(takeDifference(_:)): return model.canTakeOver && model.diffAtCursor != nil
        case #selector(takeAllDifferences(_:)): return model.canTakeOver
        case #selector(fillSelection(_:)): return hexView.selection != nil && !file.isReadOnly
        case #selector(goBack(_:)): return model.history.canGoBack
        case #selector(goForward(_:)): return model.history.canGoForward
        case #selector(selectParentStructure(_:)): return model.structure.result != nil
        case #selector(selectNextRecord(_:)), #selector(selectPreviousRecord(_:)): return hexView.selection != nil
        case #selector(markSelectionEnd(_:)): return model.selectionMark != nil
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

    enum CloseDecision { case now, cancel, afterSave }

    /// Asks about unsaved changes. `.afterSave`: a save runs in the
    /// background; `whenSaved` is told once it ended (true: saved, close).
    func confirmClose(whenSaved: @escaping (Bool) -> Void) -> CloseDecision {
        if isSaving {
            afterSave.append(whenSaved)
            return .afterSave
        }
        guard file.isModified else {
            // An undo back to the saved state may not have reached refresh() yet.
            activeRecovery?.discard()
            return .now
        }
        let canKeep = activeRecovery != nil
        let a = NSAlert()
        a.messageText = L("Save changes to %@?", file.url.lastPathComponent)
        a.informativeText =
            canKeep
            ? L(
                "Your changes will be lost if you don't save them. Keep for Later stores them on this Mac, without changing the file, and offers them again the next time you open it."
            )
            : L("Your changes will be lost if you don't save them.")
        a.addButton(withTitle: L("Save"))
        a.addButton(withTitle: L("Cancel"))
        a.addButton(withTitle: L("Don't Save"))
        if canKeep { a.addButton(withTitle: L("Keep for Later")) }
        let keepForLater = NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1)
        switch a.runModal() {
        case .alertFirstButtonReturn:
            var now: Bool?
            var returned = false
            save { ok in
                if returned { whenSaved(ok) } else { now = ok }
            }
            returned = true
            if let now { return now ? .now : .cancel }
            return .afterSave
        case .alertThirdButtonReturn:
            activeRecovery?.discardNow()
            return .now
        case keepForLater: return keepChangesForLater() ? .now : .cancel
        default: return .cancel
        }
    }

    // MARK: Auto-recovery (#139)

    /// Records unsaved changes in the background; nil for read-only files.
    private var recovery: RecoveryAutosave?
    /// `file.editState` last handed to `recovery`.
    private var recoveryEditState = 0
    private var recoveryStatus: RecoveryStatus?

    /// Imports edit a temporary image that is gone after a crash, so they get
    /// no recovery records.
    private var activeRecovery: RecoveryAutosave? { model.importInfo == nil ? recovery : nil }

    /// Called on every refresh; acts only when the content changed.
    private func updateRecovery() {
        guard let r = activeRecovery, file.editState != recoveryEditState else { return }
        recoveryEditState = file.editState
        guard file.isModified else { return r.discard() }
        r.schedule { [weak self] in
            guard let self, file.isModified else { return nil }
            return file.recoveryContent()
        }
    }

    private func recoveryStatusChanged(_ status: RecoveryStatus) {
        guard recoveryStatus != status else { return }
        recoveryStatus = status
        refresh()
    }

    /// Writes the record now. False (and the window stays open) if that failed.
    private func keepChangesForLater() -> Bool {
        guard let r = activeRecovery else { return false }
        let status = r.writeNow(file.recoveryContent())
        recoveryEditState = file.editState
        let reason: String
        switch status {
        case .saved: return true
        case .tooLarge: reason = L("They are too large for auto-recovery. Save them to a file instead.")
        case .failed(let why): reason = why
        case .discarded: reason = ""
        }
        let a = NSAlert()
        a.messageText = L("The changes could not be kept for later.")
        a.informativeText = reason
        a.runModal()
        return false
    }

    /// Waits for pending recovery work (quitting).
    func finishRecovery() { recovery?.waitUntilIdle() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        confirmClose { [weak sender] ok in if ok { sender?.close() } } == .now
    }

    // MARK: Project state

    func projectState() -> ProjectState {
        var s = ProjectState(filePath: displayURL.standardizedFileURL.path, fileSize: file.count)
        s.bookmarks = model.bookmarks.map {
            .init(
                name: $0.name, start: $0.range.lowerBound, end: $0.range.upperBound,
                color: DocumentModel.bookmarkColors.firstIndex(of: $0.color) ?? 0)
        }
        if let u = model.structure.formatURL { s.format = .init(path: u.path, title: model.structure.formatTitle ?? u.lastPathComponent) }
        s.yaraRules = model.yara.ruleFiles.map(\.path)
        s.cursor = hexView.cursor
        s.selectionStart = hexView.selection?.lowerBound
        s.selectionEnd = hexView.selection?.upperBound
        s.offsetBase = model.offsetBase
        s.highlightRules = model.rules.fileRules
        return s
    }

    /// The last state whose size mismatch was reported, so opening a project
    /// that is also the file's remembered state warns only once.
    private var sizeWarningShown: ProjectState?

    /// Applies a remembered or imported state; offsets past the end are dropped.
    func apply(_ s: ProjectState) {
        let n = file.count
        if n != s.fileSize, !s.bookmarks.isEmpty, s != sizeWarningShown {
            sizeWarningShown = s
            let a = NSAlert()
            a.messageText = L("%@ has changed since the project was saved.", displayURL.lastPathComponent)
            a.informativeText = L("Size then %1$llu bytes, now %2$llu bytes. Bookmarks may have shifted.", s.fileSize, n)
            a.runModal()
        }
        model.bookmarks = s.bookmarks.filter { $0.start < n }.map {
            DocumentModel.Bookmark(
                name: $0.name, range: $0.start ..< min(n, max($0.start + 1, $0.end)),
                color: DocumentModel.bookmarkColors[$0.color % DocumentModel.bookmarkColors.count])
        }
        if let f = s.format, FileManager.default.fileExists(atPath: f.path) {
            model.structure.apply(URL(fileURLWithPath: f.path), title: f.title, snapshot: file.snapshot())
        }
        let rules = s.yaraRules.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !rules.isEmpty { model.yara.ruleFiles = rules }
        if model.importInfo == nil, s.offsetBase != 0 { model.offsetBase = s.offsetBase }
        model.rules.fileRules = s.highlightRules
        if let a = s.selectionStart, let b = s.selectionEnd, a < b, b <= n {
            hexView.jump(to: a, select: a ..< b, record: false)
        } else {
            hexView.jump(to: min(s.cursor, n), select: nil, record: false)
        }
        refresh()
    }

    func restoreProject() {
        // On a read error saveProject() leaves the file alone.
        do { if let s = try ProjectStore.read(for: displayURL) { apply(s) } } catch { showError(error) }
    }

    func saveProject() {
        // Fails without writing if the project file is unreadable (reported on open).
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
        recovery?.stop()
        fileWatch?.cancel()
        saveProject()
        model.cancelBackgroundWork()
        model.cancelChecksums()
        onClose?(self)
    }
}

extension Notification.Name {
    static let hexwerkVimChanged = Notification.Name("hexwerkVimChanged")
}
