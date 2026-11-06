import AppKit
import HexwerkCore

// UI language (app menu → Language), applied before any UI exists.
// AppKit's own texts (alert buttons, system menu items) follow AppleLanguages.
switch Settings.shared.string(forKey: "language") {
case "en": L10n.override = .en; UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
case "de": L10n.override = .de; UserDefaults.standard.set(["de"], forKey: "AppleLanguages")
default: UserDefaults.standard.removeObject(forKey: "AppleLanguages")
}

// Offscreen rendering for checks without clicking through the app:
//   HexwerkApp --snapshot <file> <image.png> [row]
//       hex view only, reports the drawing time (SPEC TC-1.8)
//   HexwerkApp --window <file> <image.png> [hex-search | :struct] [dark]
//       whole window content (find bar, grid, sidebar, status bar)
let args = CommandLine.arguments
if args.count >= 4, args[1] == "--snapshot" || args[1] == "--window" {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        do {
            let doc = try Document(url: URL(fileURLWithPath: args[2]), readOnly: false)
            let out = URL(fileURLWithPath: args[3])
            if args[1] == "--snapshot" {
                let model = DocumentModel(doc: doc)   // HexView holds it unowned
                let view = HexView(model: model)
                view.frame = NSRect(x: 0, y: 0, width: 760, height: 900)
                view.appearance = NSAppearance(named: .aqua)
                view.layoutSubtreeIfNeeded()
                if args.count >= 5, let row = UInt64(args[4]) { view.scroll(toRow: row) }
                let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                let runs = 50
                let t0 = Date()
                for _ in 0..<runs { view.cacheDisplay(in: view.bounds, to: rep) }
                let ms = Date().timeIntervalSince(t0) * 1000 / Double(runs)
                try rep.representation(using: .png, properties: [:])!.write(to: out)
                print(String(format: "Drawing one page: %.2f ms (mean of %d)", ms, runs))
                withExtendedLifetime(model) {}
            } else {
                let c = DocumentWindowController(file: doc)
                let window = c.window!
                window.appearance = NSAppearance(named: args.count >= 6 && args[5] == "dark" ? .darkAqua : .aqua)
                window.setContentSize(NSSize(width: 1180, height: 640))
                if args.count >= 5, args[4] == ":struct" {
                    c.model.sidebarTab = .structure
                    let until = Date().addingTimeInterval(2)
                    while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
                    if let leaf = c.model.structure.rows.dropFirst(4).first?.node, let r = leaf.range {
                        c.hexView.jump(to: r.lowerBound, select: r)
                    }
                    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                } else if args.count >= 5 {
                    c.model.findVisible = true
                    c.model.findText = args[4]
                    c.model.runSearch()
                    // Let the background search finish and the UI settle.
                    let until = Date().addingTimeInterval(1.5)
                    while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
                }
                window.contentView!.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                let v = window.contentView!
                let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
                v.cacheDisplay(in: v.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])!.write(to: out)
            }
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
