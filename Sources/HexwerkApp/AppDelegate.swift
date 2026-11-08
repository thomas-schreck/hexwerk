import AppKit
import HexwerkCore
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var controllers: [DocumentWindowController] = []
    private var openedAtLaunch = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        ImportCache.user.removeAll()  // left over from a crash
        NSApp.mainMenu = buildMenu()
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        for path in args { open(URL(fileURLWithPath: path), readOnly: false) }
        if controllers.isEmpty && !openedAtLaunch { openDocument(nil) }
        NSApp.activate()
        UpdateChecker.shared.start()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        openedAtLaunch = true
        // May arrive while the app is still launching; dialogs (HEX import)
        // only show once the run loop is up.
        DispatchQueue.main.async { [self] in
            NSApp.activate()
            for url in urls { open(url, readOnly: false) }
        }
    }

    /// Background saves a quit waits for (#79); nil when no quit waits.
    private var quitWaitsForSaves: Int?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        var waiting = 0
        quitWaitsForSaves = nil
        for c in controllers {
            switch c.confirmClose(whenSaved: { [weak self] ok in self?.saveEndedDuringQuit(ok) }) {
            case .now: break
            case .cancel: return .terminateCancel
            case .afterSave: waiting += 1
            }
        }
        guard waiting == 0 else {
            quitWaitsForSaves = waiting
            return .terminateLater
        }
        prepareQuit()
        return .terminateNow
    }

    private func saveEndedDuringQuit(_ ok: Bool) {
        guard let n = quitWaitsForSaves else { return }
        guard ok else {
            quitWaitsForSaves = nil
            NSApp.reply(toApplicationShouldTerminate: false)
            return
        }
        quitWaitsForSaves = n - 1
        guard n == 1 else { return }
        quitWaitsForSaves = nil
        prepareQuit()
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    private func prepareQuit() {
        for c in controllers { c.saveProject() }
        Settings.shared.flush()
    }

    /// Windows do not close on quit, so their onClose cleanup does not run.
    func applicationWillTerminate(_ notification: Notification) {
        ImportCache.user.removeAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Calculator

    /// The document window the calculator refers to (the panel itself is
    /// key while typing, so this is the main window).
    private var frontController: DocumentWindowController? {
        controllers.first { $0.window?.isMainWindow == true } ?? controllers.first { $0.window?.isVisible == true }
    }

    @objc func toggleCalculator(_ sender: Any?) {
        let calc = CalculatorPanel.shared.model
        calc.context = { [weak self] in self?.frontController?.calculatorVariables() ?? [:] }
        calc.goTo = { [weak self] v in self?.frontController?.goToValue(v) }
        CalculatorPanel.shared.toggle()
    }

    // MARK: Opening

    @objc func openDocument(_ sender: Any?) { runOpenPanel(readOnly: false) }
    @objc func openDocumentReadOnly(_ sender: Any?) { runOpenPanel(readOnly: true) }

    private func runOpenPanel(readOnly: Bool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.title = readOnly ? L("Open Read-Only") : L("Open")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { open(url, readOnly: readOnly) }
    }

    /// Opens new files as tabs of the frontmost document window (like 010
    /// Editor); the tab bar stays visible even with a single file.
    private func showAsTab(_ c: DocumentWindowController) {
        guard let window = c.window else { return }
        let host =
            controllers.lazy.compactMap(\.window)
            .first { $0 !== window && ($0.isMainWindow || $0.isKeyWindow) }
            ?? controllers.lazy.compactMap(\.window).first { $0 !== window && $0.isVisible }
        if let host {
            host.addTabbedWindow(window, ordered: .above)
        }
        window.makeKeyAndOrderFront(nil)
        if let group = window.tabGroup, !group.isTabBarVisible { window.toggleTabBar(nil) }
    }

    /// "+" in the tab bar and ⌘T: choose files, open them as tabs.
    @objc func newWindowForTab(_ sender: Any?) { openDocument(sender) }

    /// A `.hexwerk` project: open its file and apply the saved state.
    private func openProject(_ url: URL) {
        guard let s = ProjectStore.load(url) else {
            let a = NSAlert()
            a.messageText = L("%@ is not a readable project file.", url.lastPathComponent)
            a.runModal()
            return
        }
        let target = ProjectStore.target(of: url, s)
        guard FileManager.default.fileExists(atPath: target.path) else {
            let a = NSAlert()
            a.messageText = L("The project's file is missing.")
            a.informativeText = s.filePath
            a.runModal()
            return
        }
        open(target, readOnly: false)
        let c = controllers.first { $0.displayURL.standardizedFileURL == target.standardizedFileURL }
        c?.apply(s)
    }

    static let hexRecordExtensions: Set<String> = ["hex", "ihex", "ihx", "srec", "s19", "s28", "s37", "mot"]

    /// Intel HEX / S-Record: import into a binary image at its load address,
    /// or open the text as is. Returns true if the file was handled here.
    private func openHexRecords(_ url: URL, readOnly: Bool) -> Bool {
        // Before reading, so a change while importing is noticed on save.
        let stamp = try? DiskStamp(url)
        guard Self.hexRecordExtensions.contains(url.pathExtension.lowercased()),
            let text = try? String(contentsOf: url, encoding: .ascii),
            let format = HexRecords.Format.detect(text[...])
        else { return false }
        let a = NSAlert()
        a.messageText = L("%1$@ is %2$@.", url.lastPathComponent, format.rawValue)
        a.informativeText = L("Import shows the bytes at their addresses; Save writes %@ again.", format.rawValue)
        a.addButton(withTitle: L("Import"))
        a.addButton(withTitle: L("Open as Text"))
        guard a.runModal() == .alertFirstButtonReturn else { return false }
        do {
            let image = try HexRecords.parse(text)
            let data = try image.flatten()
            let dir = try ImportCache.user.makeDirectory()
            let bin = dir.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".bin")
            try data.write(to: bin)
            let doc = try Document(url: bin, readOnly: readOnly)
            let c = DocumentWindowController(file: doc)
            c.model.offsetBase = image.base
            c.model.importInfo = .init(
                source: url, format: format, base: image.base, gaps: image.gaps, start: image.startAddress,
                startSegment: image.startSegment, header: image.header)
            c.importStamp = stamp
            c.onClose = { [weak self] closed in
                self?.controllers.removeAll { $0 === closed }
                try? FileManager.default.removeItem(at: dir)
            }
            controllers.append(c)
            showAsTab(c)
            c.refreshTitle()
            c.restoreProject()
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            if !image.warnings.isEmpty {
                let w = NSAlert()
                w.messageText = L("%@ was imported with warnings.", url.lastPathComponent)
                w.informativeText = image.warnings.joined(separator: "\n")
                w.runModal()
            }
        } catch {
            let e = NSAlert()
            e.messageText = L("%@ cannot be imported.", url.lastPathComponent)
            e.informativeText = String(describing: error)
            e.runModal()
        }
        return true
    }

    func open(_ url: URL, readOnly: Bool) {
        if controllers.contains(where: { $0.model.importInfo?.source.standardizedFileURL == url.standardizedFileURL }) {
            controllers.first { $0.model.importInfo?.source.standardizedFileURL == url.standardizedFileURL }?.showWindow(nil)
            return
        }
        if url.pathExtension.lowercased() == "hexwerk" { openProject(url); return }
        if openHexRecords(url, readOnly: readOnly) { return }
        // Via a symlink it is still the same file: one window, one undo history.
        let real = url.resolvingSymlinksInPath()
        if let existing = controllers.first(where: { $0.file.url.resolvingSymlinksInPath() == real }) {
            existing.showWindow(nil)
            return
        }
        do {
            let doc = try Document(url: url, readOnly: readOnly)
            let c = DocumentWindowController(file: doc)
            c.onClose = { [weak self] closed in self?.controllers.removeAll { $0 === closed } }
            controllers.append(c)
            showAsTab(c)
            c.restoreProject()
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            let a = NSAlert()
            a.messageText = L("%@ cannot be opened.", url.lastPathComponent)
            a.informativeText = String(describing: error)
            a.runModal()
        }
    }

    // MARK: Menu

    private func buildMenu() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: L("About hexwerk"), action: #selector(showAbout(_:)), keyEquivalent: "")
        app.addItem(UpdateChecker.shared.menuItem)
        app.addItem(withTitle: L("Check for Updates…"), action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        app.addItem(
            withTitle: L("Check for Updates Automatically"), action: #selector(toggleAutomaticUpdateCheck(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(submenu(languageMenu(), L("Language")))
        app.addItem(.separator())
        app.addItem(withTitle: L("Hide hexwerk"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: L("Quit hexwerk"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(app, "hexwerk"))

        let file = NSMenu()
        file.addItem(withTitle: L("Open…"), action: #selector(openDocument(_:)), keyEquivalent: "o")
        let ro = file.addItem(withTitle: L("Open Read-Only…"), action: #selector(openDocumentReadOnly(_:)), keyEquivalent: "o")
        ro.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(.separator())
        file.addItem(withTitle: L("Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.addItem(withTitle: L("Save"), action: #selector(DocumentWindowController.saveDocument(_:)), keyEquivalent: "s")
        let saveAs = file.addItem(
            withTitle: L("Save As…"), action: #selector(DocumentWindowController.saveDocumentAs(_:)), keyEquivalent: "s")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(.separator())
        file.addItem(withTitle: L("Export Project…"), action: #selector(DocumentWindowController.exportProject(_:)), keyEquivalent: "")
        file.addItem(withTitle: L("Export Selection…"), action: #selector(DocumentWindowController.exportSelection(_:)), keyEquivalent: "")
        for (i, f) in HexRecords.Format.allCases.enumerated() {
            file.addItem(
                withTitle: L("Export as %@…", f.rawValue), action: #selector(DocumentWindowController.exportHexRecords(_:)),
                keyEquivalent: ""
            ).tag = i
        }
        main.addItem(submenu(file, L("File")))

        let edit = NSMenu()
        edit.addItem(withTitle: L("Undo"), action: #selector(HexView.undo(_:)), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: L("Redo"), action: #selector(HexView.redo(_:)), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: L("Cut"), action: #selector(HexView.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L("Copy"), action: #selector(HexView.copy(_:)), keyEquivalent: "c")
        let copyAs = NSMenu()
        for (i, f) in ExportFormat.allCases.enumerated() {
            copyAs.addItem(withTitle: f.title, action: #selector(DocumentWindowController.copyAs(_:)), keyEquivalent: "").tag = i
        }
        copyAs.items.first?.keyEquivalent = "c"
        copyAs.items.first?.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(submenu(copyAs, L("Copy As")))
        edit.addItem(withTitle: L("Paste"), action: #selector(HexView.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L("Select All"), action: #selector(HexView.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: L("Insert Mode"), action: #selector(DocumentWindowController.toggleInsertMode(_:)), keyEquivalent: "i")
        edit.addItem(withTitle: L("Fill Selection…"), action: #selector(DocumentWindowController.fillSelection(_:)), keyEquivalent: "")
        edit.addItem(withTitle: L("Go to Offset…"), action: #selector(DocumentWindowController.goToOffset(_:)), keyEquivalent: "l")
        edit.addItem(withTitle: L("Add Bookmark…"), action: #selector(DocumentWindowController.addBookmark(_:)), keyEquivalent: "d")
        // Navigation and selection helpers (#140). ⌘[ / ⌘] are taken by the
        // diff navigation, ⇧⌘[ / ⇧⌘] by the tabs: ⌃⌘← / ⌃⌘→ like Xcode.
        edit.addItem(.separator())
        func key(_ title: String, _ action: Selector, _ key: Int, _ mods: NSEvent.ModifierFlags) {
            let item = edit.addItem(withTitle: title, action: action, keyEquivalent: String(UnicodeScalar(key)!))
            item.keyEquivalentModifierMask = mods
        }
        key(L("Back"), #selector(DocumentWindowController.goBack(_:)), NSLeftArrowFunctionKey, [.command, .control])
        key(L("Forward"), #selector(DocumentWindowController.goForward(_:)), NSRightArrowFunctionKey, [.command, .control])
        key(
            L("Select Parent Structure"), #selector(DocumentWindowController.selectParentStructure(_:)), NSUpArrowFunctionKey,
            [.command, .control])
        key(
            L("Select Next Record"), #selector(DocumentWindowController.selectNextRecord(_:)), NSRightArrowFunctionKey,
            [.command, .option])
        key(
            L("Select Previous Record"), #selector(DocumentWindowController.selectPreviousRecord(_:)), NSLeftArrowFunctionKey,
            [.command, .option])
        key(L("Mark Selection Start"), #selector(DocumentWindowController.markSelectionStart(_:)), 0x62, [.command, .control])
        key(L("Mark Selection End"), #selector(DocumentWindowController.markSelectionEnd(_:)), 0x65, [.command, .control])
        main.addItem(submenu(edit, L("Edit")))

        let find = NSMenu()
        find.addItem(withTitle: L("Find…"), action: #selector(DocumentWindowController.showFind(_:)), keyEquivalent: "f")
        find.addItem(withTitle: L("Find Next"), action: #selector(DocumentWindowController.findNext(_:)), keyEquivalent: "g")
        let prev = find.addItem(
            withTitle: L("Find Previous"), action: #selector(DocumentWindowController.findPrevious(_:)), keyEquivalent: "g")
        prev.keyEquivalentModifierMask = [.command, .shift]
        find.addItem(.separator())
        find.addItem(withTitle: L("Compare with File…"), action: #selector(DocumentWindowController.compareWithFile(_:)), keyEquivalent: "")
        find.addItem(withTitle: L("Next Difference"), action: #selector(DocumentWindowController.nextDifference(_:)), keyEquivalent: "]")
        find.addItem(
            withTitle: L("Previous Difference"), action: #selector(DocumentWindowController.previousDifference(_:)), keyEquivalent: "[")
        find.addItem(
            withTitle: L("Take Difference from Other File"), action: #selector(DocumentWindowController.takeDifference(_:)),
            keyEquivalent: "")
        find.addItem(
            withTitle: L("Take All Differences from Other File"), action: #selector(DocumentWindowController.takeAllDifferences(_:)),
            keyEquivalent: "")
        main.addItem(submenu(find, L("Find")))

        let tools = NSMenu()
        let yara = tools.addItem(withTitle: L("YARA Scan"), action: #selector(DocumentWindowController.scanYara(_:)), keyEquivalent: "y")
        yara.keyEquivalentModifierMask = [.command, .shift]
        tools.addItem(withTitle: L("Run Script"), action: #selector(DocumentWindowController.runScript(_:)), keyEquivalent: "r")
        let calc = tools.addItem(withTitle: L("Calculator"), action: #selector(toggleCalculator(_:)), keyEquivalent: "k")
        calc.keyEquivalentModifierMask = [.command, .shift]
        tools.addItem(
            withTitle: L("Entropy and Byte Distribution"), action: #selector(DocumentWindowController.showAnalysis(_:)), keyEquivalent: "")
        main.addItem(submenu(tools, L("Tools")))

        let view = NSMenu()
        let bpr = NSMenu()
        for (title, tag) in [("8", 8), ("16", 16), ("32", 32), (L("Fit to Window"), 0)] {
            bpr.addItem(withTitle: title, action: #selector(DocumentWindowController.setBytesPerRow(_:)), keyEquivalent: "").tag = tag
        }
        view.addItem(submenu(bpr, L("Bytes per Row")))
        view.addItem(
            withTitle: L("Decimal Offsets"), action: #selector(DocumentWindowController.toggleDecimalOffsets(_:)), keyEquivalent: "")
        view.addItem(withTitle: L("Base Address…"), action: #selector(DocumentWindowController.setBaseAddress(_:)), keyEquivalent: "")
        view.addItem(withTitle: L("Vim Key Bindings"), action: #selector(DocumentWindowController.toggleVim(_:)), keyEquivalent: "")
        let cs = NSMenu()
        for (i, enc) in TextEncodingView.allCases.enumerated() {
            cs.addItem(withTitle: enc.rawValue, action: #selector(DocumentWindowController.setCharset(_:)), keyEquivalent: "").tag = i
        }
        view.addItem(submenu(cs, L("Character Set")))
        view.addItem(.separator())
        let insp = view.addItem(
            withTitle: L("Show/Hide Inspector"), action: #selector(NSSplitViewController.toggleInspector(_:)), keyEquivalent: "i")
        insp.keyEquivalentModifierMask = [.command, .option]
        main.addItem(submenu(view, L("View")))

        let window = NSMenu()
        window.addItem(withTitle: L("Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(.separator())
        window.addItem(withTitle: L("New Tab…"), action: #selector(newWindowForTab(_:)), keyEquivalent: "t")
        let nextTab = window.addItem(withTitle: L("Show Next Tab"), action: #selector(NSWindow.selectNextTab(_:)), keyEquivalent: "]")
        nextTab.keyEquivalentModifierMask = [.command, .shift]
        let prevTab = window.addItem(
            withTitle: L("Show Previous Tab"), action: #selector(NSWindow.selectPreviousTab(_:)), keyEquivalent: "[")
        prevTab.keyEquivalentModifierMask = [.command, .shift]
        window.addItem(withTitle: L("Move Tab to New Window"), action: #selector(NSWindow.moveTabToNewWindow(_:)), keyEquivalent: "")
        window.addItem(withTitle: L("Merge All Windows"), action: #selector(NSWindow.mergeAllWindows(_:)), keyEquivalent: "")
        main.addItem(submenu(window, L("Window")))
        NSApp.windowsMenu = window
        return main
    }

    // MARK: Language

    /// Values of the "language" setting, in menu order (tag = index).
    private static let languages = ["system", "en", "de"]

    private func languageMenu() -> NSMenu {
        let menu = NSMenu()
        // Language names stay in their own language.
        for (i, title) in [L("System"), "English", "Deutsch"].enumerated() {
            menu.addItem(withTitle: title, action: #selector(setLanguage(_:)), keyEquivalent: "").tag = i
            if i == 0 { menu.addItem(.separator()) }
        }
        return menu
    }

    /// Stored in settings.json; main.swift applies it at the next launch.
    @objc func setLanguage(_ sender: NSMenuItem) {
        let lang = Self.languages[sender.tag]
        guard lang != (Settings.shared.string(forKey: "language") ?? "system") else { return }
        Settings.shared.set(lang, forKey: "language")
        let a = NSAlert()
        a.messageText = L("The language changes after restarting hexwerk.")
        a.runModal()
    }

    // MARK: Updates (#119)

    @objc func checkForUpdates(_ sender: Any?) { UpdateChecker.shared.checkManually() }

    @objc func toggleAutomaticUpdateCheck(_ sender: Any?) {
        UpdateChecker.shared.isEnabled.toggle()
        if UpdateChecker.shared.isEnabled { UpdateChecker.shared.start() }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleAutomaticUpdateCheck(_:)) {
            item.state = UpdateChecker.shared.isEnabled ? .on : .off
            return BuildInfo.current.version != "dev"
        }
        if item.action == #selector(setLanguage(_:)) {
            let current = Settings.shared.string(forKey: "language") ?? "system"
            item.state = Self.languages[item.tag] == current ? .on : .off
        }
        return true
    }

    private func submenu(_ menu: NSMenu, _ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menu.title = title
        item.submenu = menu
        return item
    }
}
