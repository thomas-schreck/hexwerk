// German translations: CLI. Keys are the English source texts passed to L().
extension L10n {
    static let deCLI: [String: String] = [
        // Shared arguments and options
        "File": "Datei",
        "Start offset": "Start-Offset",
        "Start offset (decimal or 0x...)": "Start-Offset (dezimal oder 0x…)",
        "Offset (decimal or 0x...)": "Offset (dezimal oder 0x…)",
        "Length": "Länge",
        "Number of bytes": "Anzahl Bytes",
        "Output as JSON": "Ausgabe als JSON",
        "Timeout in seconds": "Zeitlimit in Sekunden",
        "Unknown encoding %@": "Unbekannte Kodierung %@",
        "Offset %llu is past the end of the file (%llu)": "Offset %llu liegt hinter dem Dateiende (%llu)",

        // hexwerk, dump, inspect
        "Hex tool: view, examine and parse files.": "Hex-Werkzeug: Dateien ansehen, untersuchen, parsen.",
        "Output a range as a hex dump (format like hexdump -C).": "Bereich als Hex-Dump ausgeben (Format wie hexdump -C).",
        "Number of bytes (default: to end of file)": "Anzahl Bytes (Standard: bis Dateiende)",
        "Bytes per line": "Bytes pro Zeile",
        "--width must be between 1 and 256": "--width muss zwischen 1 und 256 liegen",
        "Interpret the bytes at an offset as data types.": "Bytes an einem Offset als Datentypen deuten.",
        "Byte order: little or big": "Byte-Reihenfolge: little oder big",

        // entropy, export
        "Entropy and byte distribution (overall and per block).": "Entropie und Byte-Verteilung (gesamt und je Block).",
        "Entropy in bits per byte: near 0 constant, near 8 compressed or encrypted.":
            "Entropie in Bit pro Byte: um 0 konstant, um 8 komprimiert oder verschlüsselt.",
        "Number of blocks for the profile": "Anzahl Blöcke für den Verlauf",
        "Output as JSON (including histogram)": "Ausgabe als JSON (inkl. Histogramm)",
        "Entropy    %@ bits/byte": "Entropie   %@ Bit/Byte",
        "Bytes      %llu, distinct %ld": "Bytes      %llu, verschieden %ld",
        "Ratios     0x00 %@ %%, printable %@ %%, ≥0x80 %@ %%": "Anteile    0x00 %@ %%, druckbar %@ %%, ≥0x80 %@ %%",
        "Profile    per %llu bytes:": "Verlauf    je %llu Byte:",
        "Output a range as raw data, hex, C array, Python, Swift or Base64.":
            "Bereich als Rohdaten, Hex, C-Array, Python, Swift oder Base64 ausgeben.",
        "Format: %@": "Format: %@",
        "Variable name for c/python/swift": "Variablenname für c/python/swift",
        "Write to a file instead of stdout": "In Datei schreiben statt auf stdout",

        // convert
        "Convert between binary, Intel HEX and Motorola S-Record.": "Zwischen Binärdatei, Intel HEX und Motorola S-Record umwandeln.",
        "Formats are detected by file extension (.hex/.ihex -> Intel HEX, .srec/.s19/.s28/.s37/.mot -> S-Record, otherwise binary) or set with --from/--to.":
            "Formate werden an der Endung erkannt (.hex/.ihex → Intel HEX, .srec/.s19/.s28/.s37/.mot → S-Record, sonst binär) oder mit --from/--to gesetzt.",
        "Input": "Eingabe",
        "Output": "Ausgabe",
        "Input format": "Eingabeformat",
        "Output format": "Ausgabeformat",
        "Start address when writing HEX/S-Record from binary": "Startadresse beim Schreiben von HEX/S-Record aus binär",
        "Fill byte for gaps when writing binary (hex)": "Füllbyte für Lücken beim Schreiben als binär (hex)",
        "--fill expects a hex byte": "--fill erwartet ein Hex-Byte",
        "--base moves the data past the end of the address space": "--base verschiebt die Daten über das Ende des Adressraums hinaus",
        "%ld segment(s) from 0x%llX, %ld bytes, %ld gap(s)": "%ld Segment(e) ab 0x%llX, %ld Byte, %ld Lücke(n)",

        // open
        "Open files in the hexwerk app (one tab per file).": "Dateien in der hexwerk-App öffnen (je Datei ein Tab).",
        "One or more files.": "Eine oder mehrere Dateien.",
        "%@: file not found.": "%@: Datei nicht gefunden.",
        "%@ is a folder.": "%@ ist ein Ordner.",
        "hexwerk.app not found or cannot be launched (make install-app).":
            "hexwerk.app nicht gefunden oder nicht startbar (make install-app).",

        // parse
        "Parse a file with a Kaitai Struct description (.ksy).": "Datei mit einer Kaitai-Struct-Beschreibung (.ksy) zerlegen.",
        "Formats from the collection (%@) via --format, your own via --ksy.":
            "Formate aus der Sammlung (%@) per --format, eigene per --ksy.",
        "Path to a .ksy file": "Pfad zu einer .ksy-Datei",
        "Format ID from the collection, e.g. png or zip": "Format-ID aus der Sammlung, z. B. png oder zip",
        "Maximum output depth": "Maximale Tiefe der Ausgabe",
        "Specify exactly one of --ksy or --format": "Genau eins von --ksy oder --format angeben",
        "Format %@ not in %@ (make formats)": "Format %@ nicht in %@ (make formats)",
        "Parse error: %@": "Fehler beim Zerlegen: %@",
        "… %ld more": "… %ld weitere",

        // script
        "Apply a JavaScript script to a file.": "JavaScript-Skript auf eine Datei anwenden.",
        "Without --write, changes are only counted, not saved. Exit 2 on script error, 3 on timeout.":
            "Ohne --write werden Änderungen nur gezählt, nicht gespeichert. Exit 2 bei Skriptfehler, 3 bei Zeitlimit.",
        "API (global object hw):": "API (globales Objekt hw):",
        "Script file (.js); with -e, code instead": "Skriptdatei (.js); mit -e stattdessen Code",
        "First argument is code instead of a file name": "Erstes Argument ist Code statt Dateiname",
        "Write changes to the file": "Änderungen in die Datei schreiben",
        "%ld change(s) not saved (--write)": "%ld Änderung(en) nicht gespeichert (--write)",

        // find
        "Search for a pattern and print the offsets of hits.": "Muster suchen und Treffer-Offsets ausgeben.",
        "Default is hex with ?? as wildcard, e.g. \"4D 5A ?? 00\".": "Standard ist Hex mit ?? als Platzhalter, z. B. \"4D 5A ?? 00\".",
        "Pattern": "Muster",
        "Pattern type: %@": "Art des Musters: %@",
        "Encoding for --mode text: ascii, utf8, utf16le, utf16be": "Kodierung für --mode text: ascii, utf8, utf16le, utf16be",
        "Ignore case (ASCII letters only)": "Groß-/Kleinschreibung ignorieren (nur ASCII-Buchstaben)",
        "Byte order for numbers: little or big": "Byte-Reihenfolge für Zahlen: little oder big",
        "invalid regular expression: %@": "ungültiger regulärer Ausdruck: %@",
        "%@ bytes": "%@ Byte",
        "invalid pattern \"%@\" for --mode %@": "ungültiges Muster \"%@\" für --mode %@",
        "stopped after %ld hits": "abgebrochen nach %ld Treffern",

        // diff
        "Compare two files; detects inserted and deleted bytes.": "Zwei Dateien vergleichen; erkennt eingefügte und gelöschte Bytes.",
        "Output per difference: offset in A, offset in B, kind. Exit 0 if the files are equal, 1 if they differ, 2 on errors.":
            "Ausgabe je Unterschied: Offset in A, Offset in B, Art. Exit 0 bei gleichen Dateien, 1 bei Unterschieden, 2 bei Fehlern.",
        "First file (A)": "Erste Datei (A)",
        "Second file (B)": "Zweite Datei (B)",
        "Compare at the same offsets only (no realignment)": "Nur an gleichen Offsets vergleichen (ohne Neuausrichtung)",
        "%ld → %ld bytes replaced": "%ld → %ld Byte ersetzt",
        "%ld bytes only in B": "%ld Byte nur in B",
        "%ld bytes only in A": "%ld Byte nur in A",

        // hash
        "Checksums over a file or range.": "Prüfsummen über Datei oder Bereich.",
        "Algorithms: %@": "Algorithmen: %@",
        "Algorithms, comma-separated; 'all' for all, 'common' for CRC32/MD5/SHA-1/SHA-256":
            "Algorithmen, durch Komma getrennt; „all“ für alle, „common“ für CRC32/MD5/SHA-1/SHA-256",
        "unknown algorithm %@ (see --help)": "unbekannter Algorithmus %@ (siehe --help)",

        // strings
        "Find printable strings (like strings, with UTF-8 and UTF-16).":
            "Druckbare Zeichenketten finden (wie strings, mit UTF-8 und UTF-16).",
        "Minimum length in characters": "Mindestlänge in Zeichen",
        "Encodings: ascii, utf8, utf16le, utf16be (comma-separated)": "Kodierungen: ascii, utf8, utf16le, utf16be (Komma-getrennt)",

        // type
        "Detect the file type (libmagic + signatures) and search for embedded files.":
            "Dateityp erkennen (libmagic + Signaturen) und eingebettete Dateien suchen.",
        "Also search for embedded files (like binwalk)": "Auch eingebettete Dateien suchen (wie binwalk)",
        "Type       %@": "Typ        %@",
        "— (no libmagic database)": "— (keine libmagic-Datenbank)",
        "Signature  %@": "Signatur   %@",
        " → Kaitai format %@": " → Kaitai-Format %@",
        "Embedded: nothing found": "Eingebettet: nichts gefunden",
        "Embedded (%ld):": "Eingebettet (%ld):",

        // yara
        "Scan a file with YARA rules (YARA-X %@).": "Datei mit YARA-Regeln scannen (YARA-X %@).",
        "Rules: a file or a folder (all .yar/.yara in it). Exit 2 on compile error, 3 on timeout.":
            "Regeln: eine Datei oder ein Ordner (alle .yar/.yara darin). Exit 2 bei Kompilierfehler, 3 bei Zeitlimit.",
        "Rule file or folder with rules": "Regeldatei oder Ordner mit Regeln",
        "File to scan": "Zu scannende Datei",
        "Scan only from this offset (decimal or 0x...)": "Nur ab diesem Offset scannen (dezimal oder 0x…)",
        "Scan only this many bytes": "Nur so viele Bytes scannen",
        "Print matching bytes per pattern (like yr -s)": "Treffer-Bytes je Pattern ausgeben (wie yr -s)",
        "Warning: %@": "Warnung: %@",
        "Offset is past the end of the file": "Offset hinter dem Dateiende",
        "%@: not found": "%@: nicht gefunden",
        "no .yar/.yara files in %@": "keine .yar/.yara-Dateien in %@",
    ]
}
