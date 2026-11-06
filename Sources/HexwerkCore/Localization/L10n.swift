import Foundation

/// Minimal localization for app, CLI and libraries (issue #40).
///
/// Apple's String Catalog tooling is not part of the Command Line Tools and
/// the CLI has no resource bundle, so translations are compiled in: source
/// texts are English literals passed to `L(…)`, German translations live in
/// the `de*` tables next to this file. `LocalizationTests` checks that every
/// `L("…")` literal has a translation with the same format specifiers.
public enum L10n {
    public enum Language: String, Sendable, CaseIterable {
        case en, de
    }

    /// Forced language (app setting, tests). nil: follow the environment.
    nonisolated(unsafe) public static var override: Language?

    public static var language: Language { override ?? detected }

    static let detected = resolve(environment: ProcessInfo.processInfo.environment,
                                  preferred: Locale.preferredLanguages)

    /// `HEXWERK_LANG`, then the POSIX locale variables (set in terminals),
    /// then the macOS language list (GUI apps get no LANG).
    static func resolve(environment env: [String: String], preferred: [String]) -> Language {
        for key in ["HEXWERK_LANG", "LC_ALL", "LC_MESSAGES", "LANG"] {
            if let v = env[key], !v.isEmpty { return language(of: v) }
        }
        return preferred.first.map(language(of:)) ?? .en
    }

    static func language(of identifier: String) -> Language {
        identifier.lowercased().hasPrefix("de") ? .de : .en
    }

    static let tables: [Language: [String: String]] = [
        .de: deCore.merging(deKaitai) { a, _ in a }
            .merging(deCLI) { a, _ in a }
            .merging(deApp) { a, _ in a },
    ]

    public static func translate(_ key: String) -> String {
        tables[language]?[key] ?? key
    }
}

/// Localized text for an English source literal. Always pass a literal so
/// the test can find it; use `%@`, `%d`, `%lld`, `%llu` … for values.
public func L(_ key: String) -> String {
    L10n.translate(key)
}

/// Marks an English literal as translatable without translating it yet:
/// the value stays stable (e.g. for JSON output) and is translated at display
/// time with `L10n.translate(_:)`. The tests treat it like `L("…")`.
public func LKey(_ key: String) -> String {
    key
}

public func L(_ key: String, _ args: any CVarArg...) -> String {
    // No locale on purpose: offsets and sizes must not get thousands
    // separators, and decimals keep the point in both languages.
    String(format: L10n.translate(key), arguments: args)
}
