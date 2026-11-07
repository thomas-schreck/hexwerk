import AppKit
import HexwerkCore
import HexwerkMagic
import HexwerkYARA

extension AppDelegate {
    /// Standard About panel with build details, license, repository link and
    /// the versions of the bundled libraries.
    @objc func showAbout(_ sender: Any?) {
        let info = BuildInfo.current
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationVersion: info.version,
            .credits: AboutPanel.credits(),
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "© 2026 Thomas Schreck",
        ]
        // Shown in parentheses after the version; empty hides the default "(1)".
        options[.version] = info.details ?? ""
        NSApp.orderFrontStandardAboutPanel(options: options)
    }
}

@MainActor
enum AboutPanel {
    static let repository = URL(string: "https://github.com/thomas-schreck/hexwerk")!
    /// Notices at the commit this build came from, so they match the bundled
    /// library versions; `main` for builds without a commit.
    static var notices: URL {
        repository.appending(path: "blob/\(BuildInfo.current.commit ?? "main")/THIRD_PARTY_NOTICES.md")
    }

    static func credits() -> NSAttributedString {
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        center.paragraphSpacing = 6
        let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let base: [NSAttributedString.Key: Any] = [
            .font: small, .foregroundColor: NSColor.labelColor, .paragraphStyle: center,
        ]
        let muted = base.merging([.foregroundColor: NSColor.secondaryLabelColor]) { $1 }

        let text = NSMutableAttributedString()
        text.append(
            NSAttributedString(string: L("Hex editor for macOS with Kaitai Struct formats, YARA-X and scripting.") + "\n", attributes: base)
        )
        text.append(NSAttributedString(string: "github.com/thomas-schreck/hexwerk", attributes: base.merging([.link: repository]) { $1 }))
        text.append(NSAttributedString(string: "\n" + L("Released under the MIT License.") + "\n", attributes: base))
        text.append(
            NSAttributedString(
                string: L("Includes YARA-X %@ (BSD-3-Clause) and libmagic %@ (BSD-2-Clause).", YaraX.version, Magic.version) + "\n",
                attributes: muted))
        text.append(NSAttributedString(string: L("Third-Party Notices"), attributes: muted.merging([.link: notices]) { $1 }))
        return text
    }
}
