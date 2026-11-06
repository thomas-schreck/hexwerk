import AppKit
import HexwerkCore
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [DocumentWindowController] = []
    private var openedAtLaunch = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMenu()
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        for path in args { open(URL(fileURLWithPath: path), readOnly: false) }
        if controllers.isEmpty && !openedAtLaunch { openDocument(nil) }
        NSApp.activate()
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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for c in controllers where !c.confirmClose() { return .terminateCancel }
        for c in controllers { c.saveProject() }
        return .terminateNow
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
        panel.title = readOnly ? "Schreibgeschützt öffnen" : "Öffnen"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { open(url, readOnly: readOnly) }
    }

    /// Opens new files as tabs of the frontmost document window (like 010
    /// Editor); the tab bar stays visible even with a single file.
    private func showAsTab(_ c: DocumentWindowController) {
        guard let window = c.window else { return }
        let host = controllers.lazy.compactMap(\.window)
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
            a.messageText = "\(url.lastPathComponent) ist keine lesbare Projektdatei."
            a.runModal()
            return
        }
        let target = ProjectStore.target(of: url, s)
        guard FileManager.default.fileExists(atPath: target.path) else {
            let a = NSAlert()
            a.messageText = "Die Datei des Projekts fehlt."
            a.informativeText = s.filePath
            a.runModal()
            return
        }
        open(target, readOnly: false)
        let c = controllers.first { $0.displayURL.standardizedFileURL == target.standardizedFileURL }
        if let c {
            if c.file.count != s.fileSize {
                let a = NSAlert()
                a.messageText = "\(target.lastPathComponent) hat sich seit dem Projekt geändert."
                a.informativeText = "Größe damals \(s.fileSize) Byte, jetzt \(c.file.count) Byte. Lesezeichen können verschoben sein."
                a.runModal()
            }
            c.apply(s)
        }
    }

    static let hexRecordExtensions: Set<String> = ["hex", "ihex", "ihx", "srec", "s19", "s28", "s37", "mot"]

    /// Intel HEX / S-Record: import into a binary image at its load address,
    /// or open the text as is. Returns true if the file was handled here.
    private func openHexRecords(_ url: URL, readOnly: Bool) -> Bool {
        guard Self.hexRecordExtensions.contains(url.pathExtension.lowercased()),
              let text = try? String(contentsOf: url, encoding: .ascii),
              let format = HexRecords.Format.detect(text[...]) else { return false }
        let a = NSAlert()
        a.messageText = "\(url.lastPathComponent) ist \(format.rawValue)."
        a.informativeText = "Importieren zeigt die Bytes an ihren Adressen; Sichern schreibt wieder \(format.rawValue)."
        a.addButton(withTitle: "Importieren")
        a.addButton(withTitle: "Als Text öffnen")
        guard a.runModal() == .alertFirstButtonReturn else { return false }
        do {
            let image = try HexRecords.parse(text)
            let data = try image.flatten()
            let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("hexwerk/import/\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let bin = dir.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".bin")
            try data.write(to: bin)
            let doc = try Document(url: bin, readOnly: readOnly)
            let c = DocumentWindowController(file: doc)
            c.model.offsetBase = image.base
            c.model.importInfo = .init(source: url, format: format, gaps: image.gaps, start: image.startAddress, header: image.header)
            c.onClose = { [weak self] closed in
                self?.controllers.removeAll { $0 === closed }
                try? FileManager.default.removeItem(at: dir)
            }
            controllers.append(c)
            showAsTab(c)
            c.refreshTitle()
            c.restoreProject()
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            let e = NSAlert()
            e.messageText = "\(url.lastPathComponent) lässt sich nicht importieren."
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
        if let existing = controllers.first(where: { $0.file.url.standardizedFileURL == url.standardizedFileURL }) {
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
            a.messageText = "\(url.lastPathComponent) lässt sich nicht öffnen."
            a.informativeText = String(describing: error)
            a.runModal()
        }
    }

    // MARK: Menu

    private func buildMenu() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "Über hexwerk", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "hexwerk ausblenden", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "hexwerk beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(app, "hexwerk"))

        let file = NSMenu(title: "Ablage")
        file.addItem(withTitle: "Öffnen …", action: #selector(openDocument(_:)), keyEquivalent: "o")
        let ro = file.addItem(withTitle: "Schreibgeschützt öffnen …", action: #selector(openDocumentReadOnly(_:)), keyEquivalent: "o")
        ro.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(.separator())
        file.addItem(withTitle: "Schließen", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.addItem(withTitle: "Sichern", action: #selector(DocumentWindowController.saveDocument(_:)), keyEquivalent: "s")
        let saveAs = file.addItem(withTitle: "Sichern unter …", action: #selector(DocumentWindowController.saveDocumentAs(_:)), keyEquivalent: "s")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(.separator())
        file.addItem(withTitle: "Projekt exportieren …", action: #selector(DocumentWindowController.exportProject(_:)), keyEquivalent: "")
        file.addItem(withTitle: "Auswahl exportieren …", action: #selector(DocumentWindowController.exportSelection(_:)), keyEquivalent: "")
        for (i, f) in HexRecords.Format.allCases.enumerated() {
            file.addItem(withTitle: "Als \(f.rawValue) exportieren …", action: #selector(DocumentWindowController.exportHexRecords(_:)), keyEquivalent: "").tag = i
        }
        main.addItem(submenu(file, "Ablage"))

        let edit = NSMenu(title: "Bearbeiten")
        edit.addItem(withTitle: "Widerrufen", action: #selector(HexView.undo(_:)), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Wiederholen", action: #selector(HexView.redo(_:)), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Ausschneiden", action: #selector(HexView.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Kopieren", action: #selector(HexView.copy(_:)), keyEquivalent: "c")
        let copyAs = NSMenu(title: "Kopieren als")
        for (i, f) in ExportFormat.allCases.enumerated() {
            copyAs.addItem(withTitle: f.title, action: #selector(DocumentWindowController.copyAs(_:)), keyEquivalent: "").tag = i
        }
        copyAs.items.first?.keyEquivalent = "c"
        copyAs.items.first?.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(submenu(copyAs, "Kopieren als"))
        edit.addItem(withTitle: "Einsetzen", action: #selector(HexView.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Alles auswählen", action: #selector(HexView.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Einfügemodus", action: #selector(DocumentWindowController.toggleInsertMode(_:)), keyEquivalent: "i")
        edit.addItem(withTitle: "Auswahl füllen …", action: #selector(DocumentWindowController.fillSelection(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "Gehe zu Offset …", action: #selector(DocumentWindowController.goToOffset(_:)), keyEquivalent: "l")
        edit.addItem(withTitle: "Lesezeichen setzen …", action: #selector(DocumentWindowController.addBookmark(_:)), keyEquivalent: "d")
        main.addItem(submenu(edit, "Bearbeiten"))

        let find = NSMenu(title: "Suchen")
        find.addItem(withTitle: "Suchen …", action: #selector(DocumentWindowController.showFind(_:)), keyEquivalent: "f")
        find.addItem(withTitle: "Weitersuchen", action: #selector(DocumentWindowController.findNext(_:)), keyEquivalent: "g")
        let prev = find.addItem(withTitle: "Rückwärts suchen", action: #selector(DocumentWindowController.findPrevious(_:)), keyEquivalent: "g")
        prev.keyEquivalentModifierMask = [.command, .shift]
        find.addItem(.separator())
        find.addItem(withTitle: "Mit Datei vergleichen …", action: #selector(DocumentWindowController.compareWithFile(_:)), keyEquivalent: "")
        find.addItem(withTitle: "Nächster Unterschied", action: #selector(DocumentWindowController.nextDifference(_:)), keyEquivalent: "]")
        find.addItem(withTitle: "Vorheriger Unterschied", action: #selector(DocumentWindowController.previousDifference(_:)), keyEquivalent: "[")
        main.addItem(submenu(find, "Suchen"))

        let tools = NSMenu(title: "Werkzeuge")
        let yara = tools.addItem(withTitle: "YARA-Scan", action: #selector(DocumentWindowController.scanYara(_:)), keyEquivalent: "y")
        yara.keyEquivalentModifierMask = [.command, .shift]
        tools.addItem(withTitle: "Skript ausführen", action: #selector(DocumentWindowController.runScript(_:)), keyEquivalent: "r")
        let calc = tools.addItem(withTitle: "Rechner", action: #selector(toggleCalculator(_:)), keyEquivalent: "k")
        calc.keyEquivalentModifierMask = [.command, .shift]
        tools.addItem(withTitle: "Entropie und Byte-Verteilung", action: #selector(DocumentWindowController.showAnalysis(_:)), keyEquivalent: "")
        main.addItem(submenu(tools, "Werkzeuge"))

        let view = NSMenu(title: "Darstellung")
        let bpr = NSMenu(title: "Bytes pro Zeile")
        for (title, tag) in [("8", 8), ("16", 16), ("32", 32), ("An Fenster anpassen", 0)] {
            bpr.addItem(withTitle: title, action: #selector(DocumentWindowController.setBytesPerRow(_:)), keyEquivalent: "").tag = tag
        }
        view.addItem(submenu(bpr, "Bytes pro Zeile"))
        view.addItem(withTitle: "Offsets dezimal", action: #selector(DocumentWindowController.toggleDecimalOffsets(_:)), keyEquivalent: "")
        view.addItem(withTitle: "Vim-Tastenkürzel", action: #selector(DocumentWindowController.toggleVim(_:)), keyEquivalent: "")
        let cs = NSMenu(title: "Zeichensatz")
        for (i, enc) in TextEncodingView.allCases.enumerated() {
            cs.addItem(withTitle: enc.rawValue, action: #selector(DocumentWindowController.setCharset(_:)), keyEquivalent: "").tag = i
        }
        view.addItem(submenu(cs, "Zeichensatz"))
        view.addItem(.separator())
        let insp = view.addItem(withTitle: "Inspektor ein-/ausblenden", action: #selector(NSSplitViewController.toggleInspector(_:)), keyEquivalent: "i")
        insp.keyEquivalentModifierMask = [.command, .option]
        main.addItem(submenu(view, "Darstellung"))

        let window = NSMenu(title: "Fenster")
        window.addItem(withTitle: "Im Dock ablegen", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(.separator())
        window.addItem(withTitle: "Neuer Tab …", action: #selector(newWindowForTab(_:)), keyEquivalent: "t")
        let nextTab = window.addItem(withTitle: "Nächster Tab", action: #selector(NSWindow.selectNextTab(_:)), keyEquivalent: "]")
        nextTab.keyEquivalentModifierMask = [.command, .shift]
        let prevTab = window.addItem(withTitle: "Vorheriger Tab", action: #selector(NSWindow.selectPreviousTab(_:)), keyEquivalent: "[")
        prevTab.keyEquivalentModifierMask = [.command, .shift]
        window.addItem(withTitle: "Tab in neues Fenster bewegen", action: #selector(NSWindow.moveTabToNewWindow(_:)), keyEquivalent: "")
        window.addItem(withTitle: "Alle Fenster zusammenführen", action: #selector(NSWindow.mergeAllWindows(_:)), keyEquivalent: "")
        main.addItem(submenu(window, "Fenster"))
        NSApp.windowsMenu = window
        return main
    }

    private func submenu(_ menu: NSMenu, _ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menu.title = title
        item.submenu = menu
        return item
    }
}
