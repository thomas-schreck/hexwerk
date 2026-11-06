# hexwerk — Software Specification Document

> **Version:** 1.0 | **Status:** Draft | **Source:** design notes | **Date:** 2026-11-06

Sprache der Anforderungen: „soll“ entspricht *shall*. Priorität in eckigen
Klammern: **Must** / **Should** / **May**. Annahmen sind mit `(assumed)` markiert.

## 1. Overview

### 1.1 Zweck

hexwerk ist ein Hex-Editor für macOS, geschrieben in Swift, als offenes Werkzeug
für Reverse Engineering. Er öffnet beliebig große Binärdateien sofort, erlaubt
Bearbeiten mit Undo, zerlegt Dateiformate anhand von **Kaitai-Struct**-
Beschreibungen (`.ksy`) und durchsucht Dateien mit **YARA-X**-Regeln. Ein
Kommandozeilen-Tool nutzt denselben Kern.

### 1.2 Zielgruppe

- Hauptnutzer: der Autor (Reverse Engineering, Forensik, Amateurfunk-/IoT-
  Firmware, Lehre IT-Sicherheit an der HM).
- Sekundär: Studierende in Übungen (lesen, nicht beitragen) (assumed).

### 1.3 Ziele

- Alle Alltagsaufgaben eines Hex-Editors abdecken (Ansehen, Bearbeiten,
  Formate parsen, Suchen, Vergleichen).
- Große Dateien (mehrere GB) ohne Wartezeit und ohne entsprechenden RAM-Bedarf.
- Formatwissen in offenem, wiederverwendbarem Format (Kaitai) statt in
  proprietären Templates.
- YARA-Treffer direkt im Kontext der Bytes sehen.
- Jede Phase liefert ein für sich benutzbares Werkzeug.

### 1.4 Nicht-Ziele

- Kein Disassembler, Decompiler oder Debugger (dafür rizin/Ghidra).
- Keine Unterstützung für Linux oder Windows; der Kern bleibt aber frei von
  AppKit, damit das CLI später portierbar wäre (assumed).
- Kein Bearbeiten von Prozess-Speicher oder Block-Devices in Version 1.
- Keine Kompatibilität mit Skript- oder Template-Sprachen anderer Hex-Editoren;
  Formate werden ausschließlich als Kaitai Struct beschrieben.
- Kein App Store, keine Notarisierung (kein Apple-Developer-Account nötig).

### 1.5 Ablauf auf hoher Ebene

1. Nutzer öffnet eine Datei (App oder CLI).
2. Der Kern bildet sie per Memory-Mapping ab; Änderungen landen in einer
   Piece Table über dem unveränderten Original.
3. Die Hex-Ansicht zeichnet nur die sichtbaren Zeilen.
4. Optional: Kaitai-Format anwenden → Strukturbaum + farbige Bereiche;
   YARA-Regeln anwenden → Trefferliste + Markierungen.
5. Speichern schreibt die Piece Table zurück (in-place oder atomar per
   Ersatzdatei).

## 2. System Architecture

### 2.1 Component Overview

Ein SwiftPM-Paket mit diesen Targets:

| Target | Art | Verantwortung |
|--------|-----|---------------|
| `HexwerkCore` | Library | `ByteSource` (mmap), `PieceTable` mit Undo/Redo, Speichern, Data-Inspector-Decoder, Suche, Diff, Hashes. Keine AppKit-Abhängigkeit. |
| `HexwerkKaitai` | Library | `.ksy` laden (YAML), Ausdruckssprache, Interpreter über `ByteReader`-Protokoll, Ergebnisbaum mit Byte-Bereichen. |
| `CYaraX` | System Library | Modulemap für die C-API von YARA-X (`yara_x.h`, `libyara_x_capi`, per pkg-config). |
| `HexwerkYARA` | Library | Swift-Hülle um `CYaraX`: Regeln kompilieren, Scan mit Timeout, Treffer als Offset/Länge. |
| `hexwerk` | Executable | CLI (swift-argument-parser) auf Basis der Libraries. |
| `HexwerkApp` | Executable | macOS-App: AppKit-Hex-Ansicht (`HexView: NSView`), SwiftUI für Fenster, Seitenleisten, Inspector. |

Abhängigkeiten zwischen Targets: `HexwerkKaitai` → `HexwerkCore`;
`HexwerkYARA` → `HexwerkCore`, `CYaraX`; `hexwerk` und `HexwerkApp` → alle
drei Libraries.

### 2.2 Tech Stack

| Schicht | Technologie | Begründung |
|---------|-------------|------------|
| Sprache | Swift 6.4, Strict Concurrency | Vorgabe; Datenrennen bei Hintergrund-Suche/Scans vermeiden. |
| Build | SwiftPM + Command Line Tools, Makefile | Kein Xcode installiert. |
| Hex-Ansicht | AppKit (`NSView`, Core Text, eigener Scroller) | Millionen Zeilen; SwiftUI-Listen sind dafür zu langsam. |
| Restliche UI | SwiftUI in `NSHostingView` | Schneller für Formulare, Listen, Inspector. |
| Dateizugriff | `mmap(2)` read-only, `MAP_PRIVATE` | Sofortiges Öffnen großer Dateien, kein Kopieren. |
| YAML | Yams (MIT) | `.ksy` ist YAML; Yams ist der verbreitete Swift-Parser. |
| CLI | swift-argument-parser (Apache-2.0) | Standard für Swift-CLIs. |
| YARA | YARA-X C-API aus Homebrew (`yara-x`, BSD-3) | Nutzerentscheidung; Homebrew-Formel installiert `libyara_x_capi` + Header, keine Rust-Toolchain nötig. |
| Formate | Kaitai Struct Format Gallery (`kaitai_struct_formats`, Einzellizenzen meist CC0/MIT) | Große offene Sammlung. |
| Tests | swift-testing aus den Command Line Tools | Makro-Plugin liegt in `usr/lib/swift/host/plugins/testing`; der Test-Target bekommt `-plugin-path` darauf (R-1, gelöst). |
| Lizenz | MIT | Nutzerentscheidung. |

### 2.3 Data Flow

**Öffnen:** Pfad → `ByteSource.open` (mmap) → `Document` mit `PieceTable`
(ein Piece: Original 0…n) → `HexView` fragt pro sichtbarer Zeile
`document.read(range)` ab.

**Bearbeiten:** Tastatureingabe → `Document.apply(Edit)` → Piece Table
splittet Pieces, neue Bytes in einen Append-Puffer → Undo-Eintrag →
`HexView` invalidiert betroffene Zeilen.

**Kaitai:** Nutzer wählt `.ksy` (oder automatische Zuordnung über
`meta.file-extension`) → `KsyLoader` → `Interpreter.parse(reader)` im
Hintergrund-Task → `ParseTree` (Knoten mit Name, Typ, Wert, Bereich) →
Strukturbaum in der Seitenleiste + farbige Bereiche in der Hex-Ansicht.

**YARA:** Regeldatei → `YaraRules.compile` → `Scanner.scan(buffer, timeout)`
im Hintergrund-Task → `[YaraMatch]` (Regel, Pattern, Offset, Länge) →
Trefferliste + Markierungen.

**Speichern:** nur Überschreibungen ohne Längenänderung → betroffene Bereiche
in-place schreiben; sonst Ersatzdatei im selben Verzeichnis schreiben, dann
atomar austauschen (`rename`/`replaceItemAt`).

### 2.4 Deployment Architecture

- Lokale Installation, keine Server-Komponente.
- `make app` baut `hexwerk.app` (Info.plist, Icon, Binary, eingebettete
  dylib-Pfade), signiert ad-hoc (`codesign -s -`), legt sie nach
  `/Applications` (wie OscarWatch).
- `make cli` installiert `hexwerk` nach `~/.local/bin` (Konvention aus
  `~/src/Makefile`).
- Repository: `git.schreck-thomas.de/ts/hexwerk` (privat). Kein CI in
  Version 1 (assumed); Tests laufen lokal per `make test`.

## 3. Implementation Phases

### 3.1 Phase 1 — Fundament: ansehen und überschreiben

- **Scope:** Paketstruktur, Test-Infrastruktur, `ByteSource`, `PieceTable`
  (nur Überschreiben), Undo/Redo, Speichern, Data Inspector, Hex-Ansicht,
  CLI `dump` und `inspect`, App-Bundle-Build.
- **Deliverables:** `hexwerk.app` öffnet beliebige Dateien, zeigt Hex/ASCII,
  Cursor, Auswahl, Überschreiben, Undo, Speichern; Data Inspector;
  `hexwerk dump`, `hexwerk inspect`.
- **Exit Criteria:** TC-1.x grün; 10-GB-Testdatei öffnet in < 1 s und scrollt
  flüssig; Speichern verändert nur die geänderten Bytes (Prüfsumme).
- **Dependencies:** keine.

### 3.2 Phase 2 — Bearbeiten und Navigieren

- **Scope:** Einfügen/Löschen (Längenänderung), Gehe-zu-Offset, Suchen und
  Ersetzen (Hex, Text, Zahl, Wildcards), Lesezeichen, Diff zweier Dateien,
  Hashes über Auswahl, CLI `find`, `diff`, `hash`.
- **Deliverables:** vollständiger Editor ohne Formatwissen.
- **Exit Criteria:** TC-2.x grün; Suche über 1 GB in < 3 s für Byte-Muster.
- **Dependencies:** Phase 1.

### 3.3 Phase 3 — Kaitai Struct

- **Scope:** `.ksy` laden, Interpreter für den Kern der Sprache (siehe
  FR-6.x), Strukturbaum, farbige Bereiche, Auswahl-Synchronisation
  Baum ↔ Hex, Formatsammlung einbinden, CLI `parse`.
- **Deliverables:** Formate aus der Kaitai-Sammlung (mindestens die
  Referenzliste in Abschnitt 11.2) werden korrekt geparst.
- **Exit Criteria:** TC-3.x grün; Referenzformate liefern dieselben Feldwerte
  wie der offizielle Kaitai-Compiler (Python-Runtime) auf den Testdateien.
  (Umgesetzt als Vergleich mit den Werten, mit denen die Testdateien erzeugt
  wurden, da Compiler und Java nicht installiert sind. ZIP mit Info-ZIP-
  Zeitstempeln bricht wie die offizielle Laufzeit im Zentralverzeichnis ab:
  Das Flag für die Zugriffszeit ist gesetzt, der Wert fehlt dort.)
- **Dependencies:** Phase 1 (Phase 2 nicht zwingend).

### 3.4 Phase 4 — YARA-X

- **Scope:** Regeln laden/kompilieren mit Fehlermeldungen, Scan der Datei
  oder Auswahl, Trefferliste, Markierungen, Timeout, CLI `yara`.
- **Deliverables:** YARA-Panel in der App, `hexwerk yara`.
- **Exit Criteria:** TC-4.x grün; Treffer stimmen mit `yr scan` (YARA-X-CLI)
  auf denselben Dateien überein.
- **Stand 2026-11-06:** erfüllt. Treffer (Regel, Pattern, Offset) identisch
  mit `yr scan` 1.23 auf 12 Dateien bis 512.965 Treffer. Abbrechen (FR-7.5)
  verwirft das Ergebnis; der Scan selbst endet spätestens am Zeitlimit, da
  die C-API keinen Abbruch kennt. Die App begrenzt auf 100.000 Treffer je
  Pattern. FR-7.7 (Metadaten, Tags) ist mit umgesetzt.
- **Dependencies:** Phase 1; Homebrew-Paket `yara-x`.

### 3.5 Phase 5 — Analyse und Komfort

- **Scope:** Entropie-/Byte-Verteilungsansicht, Kaitai-Erweiterungen
  (Bit-Felder, Process-Routinen, eigene Formate), Export von Bereichen,
  ggf. Skripting.
- **Deliverables:** nach Bedarf priorisiert.
- **Exit Criteria:** je Feature eigener Testfall.
- **Dependencies:** Phasen 1–4.
- **Stand 2026-11-06:** FR-9.1, 9.2 und 9.4 umgesetzt. Skriptsprache: JavaScript über
  das systemeigene JavaScriptCore (keine Abhängigkeit); ein Lauf ist ein
  Undo-Schritt, Fehler rollen zurück, Zeitlimit/Abbruch über den
  JSC-Watchdog.

## 4. Requirements

### 4.1 Functional Requirements (FR)

#### FR-1 Dateien und Dokumente

- **FR-1.1** [Must]: Das System soll Dateien beliebiger Größe per Memory-Mapping öffnen, ohne sie vollständig in den Speicher zu lesen.
- **FR-1.2** [Must]: Das System soll Dateien auf Wunsch schreibgeschützt öffnen; im Schreibschutz soll jede Bearbeitung abgewiesen werden.
- **FR-1.3** [Must]: Das System soll beim Speichern ohne Längenänderung nur geänderte Bereiche in-place schreiben.
- **FR-1.4** [Must]: Das System soll beim Speichern mit Längenänderung eine Ersatzdatei im Zielverzeichnis schreiben und diese atomar an die Stelle des Originals setzen.
- **FR-1.5** [Must]: Das System soll „Speichern unter“ unterstützen.
- **FR-1.6** [Should]: Das System soll erkennen, wenn die geöffnete Datei extern verändert wurde, und vor dem Speichern warnen.
- **FR-1.7** [Should]: Das System soll mehrere Dokumente in eigenen Fenstern oder Tabs öffnen.
- **FR-1.8** [May]: Das System soll leere neue Dokumente anlegen.

#### FR-2 Hex-Ansicht

- **FR-2.1** [Must]: Die Ansicht soll Offset-Spalte, Hex-Bereich und Zeichenbereich (ASCII, nicht druckbare Zeichen als Punkt) nebeneinander darstellen.
- **FR-2.2** [Must]: Die Ansicht soll nur sichtbare Zeilen lesen und zeichnen.
- **FR-2.3** [Must]: Die Ansicht soll Cursor und zusammenhängende Auswahl per Maus und Tastatur unterstützen, synchron in Hex- und Zeichenbereich.
- **FR-2.4** [Must]: Die Ansicht soll Überschreiben im Hex- und im Zeichenbereich unterstützen.
- **FR-2.5** [Must]: Geänderte, noch nicht gespeicherte Bytes sollen farblich hervorgehoben werden.
- **FR-2.6** [Should]: Die Bytes pro Zeile sollen einstellbar sein (8, 16, 32, automatisch nach Fensterbreite).
- **FR-2.7** [Should]: Offsets sollen hexadezimal oder dezimal anzeigbar sein.
- **FR-2.8** [Should]: Der Zeichenbereich soll zwischen ASCII, Latin-1 und UTF-8 umschaltbar sein. UTF-8-Zeichen stehen zentriert über allen ihren Bytes (Standard: UTF-8); im Textbereich getippte Zeichen werden in der gewählten Kodierung geschrieben.
- **FR-2.9** [Must]: Die Ansicht soll farbige Bereiche aus anderen Quellen (Kaitai, YARA, Suche, Lesezeichen) als Hintergrund darstellen.

#### FR-3 Bearbeiten

- **FR-3.1** [Must]: Das System soll Undo und Redo für alle Bearbeitungen unbegrenzt bis zum letzten Speichern (bzw. Öffnen) zurück unterstützen. Nach dem Speichern basiert das Dokument auf dem neuen Dateiinhalt; nach In-place-Speichern wäre der alte Inhalt nicht mehr lesbar.
- **FR-3.2** [Must]: Das System soll Einfügen und Löschen von Bytes (Längenänderung) unterstützen.
- **FR-3.3** [Must]: Das System soll Kopieren und Einfügen als Hex-Text und als Rohbytes unterstützen.
- **FR-3.4** [Should]: Das System soll einen Bereich mit einem Bytewert oder Muster füllen.
- **FR-3.5** [Must]: Das System soll zu einem Offset springen (absolut, relativ, hex oder dezimal).
- **FR-3.6** [Should]: Das System soll Lesezeichen mit Name und Farbe pro Dokument anlegen.

#### FR-4 Data Inspector

- **FR-4.1** [Must]: Der Inspector soll die Bytes ab Cursor als int8/16/32/64 und uint8/16/32/64 anzeigen, umschaltbar Little/Big Endian.
- **FR-4.2** [Must]: Der Inspector soll float32 und float64 anzeigen.
- **FR-4.3** [Should]: Der Inspector soll Zeitstempel als Unix (32/64 Bit), Windows FILETIME und DOS-Datum/Zeit anzeigen.
- **FR-4.4** [Should]: Der Inspector soll GUID, Binärdarstellung und ULEB128/SLEB128 anzeigen.
- **FR-4.5** [Should]: Der Inspector soll nullterminierte Strings in ASCII, UTF-8 und UTF-16 LE/BE anzeigen.
- **FR-4.6** [Should]: Werte im Inspector sollen editierbar sein und als Bytes zurückgeschrieben werden.

#### FR-5 Suchen, Vergleichen, Prüfsummen

- **FR-5.1** [Must]: Das System soll nach Byte-Folgen in Hex-Notation suchen, mit `??` als Wildcard für ein Byte.
- **FR-5.2** [Must]: Das System soll nach Text in ASCII, UTF-8 und UTF-16 LE/BE suchen, optional ohne Groß-/Kleinschreibung.
- **FR-5.3** [Should]: Das System soll nach Zahlenwerten (Integer, Float) in wählbarer Breite und Byte-Reihenfolge suchen.
- **FR-5.4** [Must]: Das System soll alle Treffer als Liste mit Offsets anzeigen und markieren.
- **FR-5.5** [Should]: Das System soll Treffer einzeln oder alle ersetzen.
- **FR-5.6** [Must]: Suchen soll im Hintergrund laufen, Fortschritt anzeigen und abbrechbar sein.
- **FR-5.7** [Should]: Das System soll zwei Dateien byteweise vergleichen und Unterschiede als Bereiche auflisten und navigierbar machen.
- **FR-5.8** [Should]: Das System soll MD5, SHA-1, SHA-256 und CRC32 über Auswahl oder Datei berechnen.

#### FR-6 Kaitai Struct

- **FR-6.1** [Must]: Das System soll `.ksy`-Dateien laden und ohne vorheriges Kompilieren zur Laufzeit interpretieren.
- **FR-6.2** [Must]: Der Interpreter soll `meta` (id, endian, encoding, imports), `seq`, `types`, `enums`, Integer- und Float-Typen, `str`/`strz` mit Encoding, `size`, `size-eos`, `contents` und Byte-Arrays unterstützen.
- **FR-6.3** [Must]: Der Interpreter soll `repeat: eos`, `repeat: expr` und `repeat: until` unterstützen.
- **FR-6.4** [Must]: Der Interpreter soll `if`, `switch-on`/`cases` und `instances` mit `pos` und `value` unterstützen.
- **FR-6.5** [Must]: Der Interpreter soll die Kaitai-Ausdruckssprache für Arithmetik, Vergleiche, Logik, Ternär-Operator, Feldzugriff, `_parent`, `_root`, `_io.size`, `_io.pos` und Enum-Literale auswerten.
- **FR-6.6** [Should]: Der Interpreter soll `process: zlib`, `process: xor(…)` und `process: rol/ror(…)` unterstützen; die verarbeiteten Daten sollen als eigener Unterstrom angezeigt werden.
- **FR-6.7** [Should]: Der Interpreter soll Bit-Felder (`b1` … `b64`) unterstützen.
- **FR-6.8** [Must]: Das Ergebnis soll als Baum (Name, Typ, Wert, Offset, Länge) angezeigt werden; Auswahl im Baum soll den Bereich in der Hex-Ansicht markieren und umgekehrt.
- **FR-6.9** [Must]: Parse-Fehler sollen den bis dahin geparsten Teilbaum erhalten und die Fehlerstelle (Offset, Feldpfad, Meldung) anzeigen.
- **FR-6.10** [Should]: Das System soll ein Format automatisch anhand von `meta.file-extension` vorschlagen.
- **FR-6.11** [Should]: Das System soll die Kaitai-Formatsammlung aus einem lokalen Checkout einbinden und `imports` darüber auflösen.
- **FR-6.12** [Should]: Eigene `.ksy`-Dateien sollen aus einem Nutzerverzeichnis geladen werden und Formate der Sammlung gleichen Namens überdecken. (Umgesetzt: `~/.config/hexwerk/ksy`.)
- **FR-6.13** [Should]: Große Arrays sollen im Baum bedarfsweise geparst bzw. aufgeklappt werden, statt vollständig vorab. (Stand 2026-11-06: Arrays einfacher Zahlentypen ab 1024 Elementen werden in einem Durchlauf ohne Knoten pro Element gelesen, ihre Baumknoten entstehen erst beim Aufklappen; alle Arrays über 1000 Einträgen zeigt der Baum in Seiten zu 1000. Arrays von Structs werden weiterhin vollständig zerlegt, Knotenlimit 1 000 000.)

#### FR-7 YARA-X

- **FR-7.1** [Must]: Das System soll YARA-Regeln aus Dateien laden und mit YARA-X kompilieren; Kompilierfehler sollen mit Datei, Zeile und Meldung angezeigt werden.
- **FR-7.2** [Must]: Das System soll die geöffnete Datei mit den kompilierten Regeln scannen.
- **FR-7.3** [Should]: Das System soll nur eine Auswahl scannen und Treffer-Offsets auf die Datei umrechnen.
- **FR-7.4** [Must]: Treffer sollen als Liste (Regel, Namespace, Pattern-ID, Offset, Länge) angezeigt und in der Hex-Ansicht markiert werden.
- **FR-7.5** [Must]: Scans sollen im Hintergrund mit einstellbarem Timeout laufen und abbrechbar sein.
- **FR-7.6** [Should]: Ein Dokument mit ungespeicherten Änderungen soll im aktuellen Zustand gescannt werden.
- **FR-7.7** [May]: Das System soll Metadaten und Tags der getroffenen Regeln anzeigen.

#### FR-8 Kommandozeile

- **FR-8.1** [Must]: `hexwerk dump` soll einen Bereich einer Datei als Hex-Dump ausgeben.
- **FR-8.2** [Must]: `hexwerk inspect` soll die Data-Inspector-Werte an einem Offset ausgeben.
- **FR-8.3** [Should]: `hexwerk find` soll Suchtreffer als Offsets ausgeben.
- **FR-8.4** [Should]: `hexwerk diff` und `hexwerk hash` sollen FR-5.7 und FR-5.8 auf der Kommandozeile bereitstellen.
- **FR-8.5** [Must]: `hexwerk parse` soll eine Datei mit einer `.ksy` parsen und den Baum als Text oder JSON ausgeben.
- **FR-8.6** [Must]: `hexwerk yara` soll eine Datei mit Regeln scannen und Treffer als Text oder JSON ausgeben.
- **FR-8.7** [Must]: Das CLI soll bei Fehlern einen Exit-Code ≠ 0 liefern und Fehlermeldungen auf stderr schreiben.
- **FR-8.8** [Should]: `hexwerk open <datei>` soll die Datei in der App öffnen.

#### FR-10 Phase 6 (Wünsche nach Phase 5)

- **FR-10.1** [Should]: Das System soll den Dateityp an Signaturen erkennen und das passende Kaitai-Format unabhängig von der Endung wählen.
- **FR-10.2** [Should]: Das System soll eine Typbeschreibung und den MIME-Typ über libmagic anzeigen.
- **FR-10.3** [Should]: Das System soll eingebettete Dateien an beliebigen Offsets finden.
- **FR-10.4** [Should]: Das System soll druckbare Zeichenketten (ASCII, UTF-8, UTF-16LE/BE) mit Mindestlänge und Filter auflisten.
- **FR-10.5** [Should]: Das System soll mit regulären Ausdrücken über Rohbytes suchen.
- **FR-10.6** [Should]: Das System soll Intel HEX und Motorola S-Record lesen (mit Prüfsummen), an ihren Adressen anzeigen und schreiben.
- **FR-10.7** [Should]: Das System soll Lesezeichen, Format, YARA-Regeln und Position je Datei merken und als Projektdatei exportieren. Sobald Lesezeichen existieren, liegt der Zustand als `<datei>.hexwerk` neben der Datei. Nur Cursor oder erkanntes Format, oder ein schreibgeschützter Ordner, landen zentral in `~/.config/hexwerk/projects`.
- **FR-10.8** [Should]: Das System soll einen Rechner für 64-Bit-Ausdrücke mit Variablen aus dem Dokument bieten.
- **FR-10.9** [May]: Das System soll optionale Vim-Tastenkürzel bieten.
- **FR-10.11** [Should]: Der Vergleich soll eingefügte und gelöschte Bytes erkennen und Offsets in beiden Dateien angeben.
- **FR-11.1** [Should]: Das System soll Bytes als Bild (Grau, RGB, RGBA, RGB565, 1 Bit) mit wählbarer Breite zeigen.
- **FR-10.10** [Should]: Das System soll alle gängigen Prüfsummen und Hashes berechnen (CRC-Varianten, Fletcher, Adler, FNV, Murmur3, xxHash, MD4/5, SHA-1/2/3, Keccak, BLAKE2/3, RIPEMD-160, SM3).

#### FR-9 Später (Phase 5)

- **FR-9.1** [May]: Das System soll eine Entropie- und Byte-Verteilungsansicht der Datei anzeigen.
- **FR-9.2** [May]: Das System soll Automatisierung per Skript anbieten (Sprache offen).
- **FR-9.3** [May]: Entfernt (Import fremder Template-Formate ist Nicht-Ziel, siehe 1.4).
- **FR-9.4** [May]: Das System soll Bereiche als Datei, C-Array oder Base64 exportieren.

### 4.2 Non-Functional Requirements (NFR)

- **NFR-1.1** [Must]: Das Öffnen einer 10-GB-Datei soll bis zur ersten Anzeige < 1 s dauern.
- **NFR-1.2** [Must]: Scrollen und Cursorbewegung sollen bei jeder Dateigröße flüssig sein (Ziel 60 fps, Zeichnen einer Bildschirmseite < 8 ms).
- **NFR-1.3** [Must]: Der Speicherbedarf soll unabhängig von der Dateigröße sein (Ziel < 200 MB ohne Bearbeitungen und ohne Parse-Baum).
- **NFR-1.4** [Should]: Die Byte-Suche ohne Wildcards soll ≥ 500 MB/s erreichen (assumed).
- **NFR-2.1** [Must]: Keine Eingabedatei, `.ksy` oder YARA-Regel soll die App oder das CLI zum Absturz bringen; alle Lesezugriffe sind bereichsgeprüft. Analysierte Dateien gelten als potenziell bösartig.
- **NFR-2.2** [Must]: Der Kaitai-Interpreter soll Grenzen für Rekursionstiefe, Knotenzahl und Laufzeit haben und bei Überschreitung sauber abbrechen.
- **NFR-2.3** [Must]: Das System soll keine Netzwerkverbindungen aufbauen.
- **NFR-2.4** [Must]: Speichern darf bei Abbruch oder Absturz niemals eine halb geschriebene Datei hinterlassen, außer im in-place-Modus, der nur Bytes gleicher Länge überschreibt.
- **NFR-3.1** [Must]: `HexwerkCore`, `HexwerkKaitai` und `HexwerkYARA` sollen ohne AppKit kompilieren.
- **NFR-3.2** [Must]: Kern-Logik (Piece Table, Decoder, Suche, Interpreter, YARA-Hülle) soll durch automatisierte Tests abgedeckt sein.
- **NFR-3.3** [Should]: Der Build soll ohne Xcode, nur mit Command Line Tools und Homebrew-Paketen, funktionieren.
- **NFR-4.1** [Should]: Die App soll Tastaturbedienung für alle Kernfunktionen bieten und macOS-Konventionen (Menüs, Kürzel, Dark Mode) folgen.
- **NFR-4.2** [May]: Die Oberfläche soll auf Deutsch und Englisch verfügbar sein.

### 4.3 Constraints

- Nur macOS auf Apple Silicon, mindestens die aktuell installierte Version (macOS 27) (assumed).
- Kein Xcode: Build, Tests und App-Bundle müssen mit SwiftPM und Shell-Skripten funktionieren.
- YARA-X kommt aus Homebrew; CLI und App linken die statische `libyara_x_capi.a` ein und starten damit unabhängig vom Homebrew-Update-Stand. Die Homebrew-Bibliothek ist für macOS 27 gebaut, deshalb ist das Deployment-Ziel macOS 27.
- wasmtime (in YARA-X) setzt Mach-Exception-Ports pro Thread. Prozesse, die das verbieten (der Apple-signierte `swiftpm-testing-helper`, ggf. Hardened Runtime), werden mit `EXC_GUARD` beendet. Scan-Tests laufen deshalb über das CLI; bei späterer Notarisierung prüfen.
- Lizenz MIT; mitgelieferte Kaitai-Formate behalten ihre Einzellizenzen (Lizenzdatei je Format mitliefern).
- Signatur nur ad-hoc; die App läuft lokal, Weitergabe an Dritte erfordert Gatekeeper-Freigabe.

## 5. Risks, Assumptions & Dependencies

| ID | Risiko | Wahrscheinlichkeit | Auswirkung | Gegenmaßnahme |
|----|--------|-------------------|-----------|---------------|
| R-1 | swift-testing läuft mit den CLT nicht: Compiler findet das Makro-Plugin `TestingMacros` nicht. | Gelöst | Mittel | Plugin liegt im Unterordner `host/plugins/testing`; `-plugin-path` im Test-Target (Package.swift). Die Paket-Variante von swift-testing scheiterte am Linken von `_TestingInterop`. |
| R-2 | `NSScrollView` verliert bei sehr hohen Dokumenten (Milliarden Pixel) Präzision. | Hoch | Hoch | Eigene virtuelle Scrollposition (Zeilenindex statt Pixel), eigener Scroller; Dokumentansicht nur bildschirmhoch. |
| R-3 | Kaitai-Ausdruckssprache und Randfälle sind umfangreicher als erwartet. | Hoch | Mittel | Feste Referenzliste an Formaten (11.2), Vergleich gegen die offizielle Python-Runtime, Features nach Bedarf der Referenzformate. |
| R-4 | YARA-X-Scan braucht einen zusammenhängenden Puffer; geänderte Dokumente müssten materialisiert werden. | Mittel | Mittel | Umgesetzt (Phase 4): liegt der Bereich in einem ungeänderten Stück, wird der mmap-Zeiger direkt übergeben; sonst wird der Bereich im Speicher zusammengesetzt (`Snapshot.withContiguousBytes`). |
| R-5 | C-API von YARA-X ändert sich zwischen Versionen (Homebrew aktualisiert automatisch). | Mittel | Mittel | Statisch gelinkt (Phase 4), Hülle schmal gehalten; ein Homebrew-Update wirkt erst beim nächsten Build. |
| R-6 | In-place-Speichern auf einer Datei, die andere Prozesse gerade mappen. | Niedrig | Hoch | FR-1.6 (Änderungserkennung); in-place nur nach Bestätigung, Standard ist Ersatzdatei (assumed). |
| R-7 | Projektumfang („alles können“) läuft aus dem Ruder. | Hoch | Mittel | Strikte Phasen, jede für sich nutzbar; Phase 5 nur nach konkretem Bedarf. |

**Annahmen:**

- Einzelnutzer, lokale Dateien; keine Mehrbenutzer- oder Netzwerkfunktionen (assumed).
- Alle Nutzerdaten liegen unter `~/.config/hexwerk` (bzw. `$XDG_CONFIG_HOME/hexwerk`): Formatsammlung als Git-Checkout in `formats`, eigene `.ksy` in `ksy`, `yara`, `scripts`, Einstellungen in `settings.json`.
- Standard-Speichern ist die Ersatzdatei-Variante; in-place nur bei gleicher Länge und mit Bestätigung oder Einstellung (assumed).
- Kein CI in Version 1; Tests lokal (assumed).

**Externe Abhängigkeiten:**

- Homebrew `yara-x` (C-API, CLI `yr` als Referenz für Tests).
- Swift-Pakete: Yams, swift-argument-parser. swift-testing kommt aus den Command Line Tools.
- `kaitai_struct_formats` (GitHub), optional `kaitai-struct-compiler` + Python-Runtime als Referenz in Tests.

## 6. Interface Specifications

### 6.1 Kern-API (Swift, Auszug)

| Typ | Wichtige Mitglieder | Zweck |
|-----|---------------------|-------|
| `ByteSource` | `init(url:readOnly:)`, `count`, `read(_ range: Range<UInt64>) -> Data` | mmap-Zugriff auf Originaldatei |
| `Document` | `count`, `read(_:)`, `apply(_ edit: Edit)`, `undo()`, `redo()`, `isModified`, `save(to:mode:)` | Bearbeitbare Sicht |
| `Edit` | `.overwrite(at:bytes:)`, `.insert(at:bytes:)`, `.delete(range:)` | Bearbeitungsoperation |
| `Inspector` | `values(at:in:endian:) -> [InspectorValue]` | Data Inspector |
| `Searcher` | `find(_ pattern: SearchPattern, in:) -> AsyncStream<Range<UInt64>>` | Suche mit Abbruch |
| `KsySchema` | `load(url:resolver:)` | `.ksy` laden, Imports auflösen |
| `KaitaiInterpreter` | `parse(_ reader: ByteReader, schema:, limits:) -> ParseResult` | Laufzeit-Parser |
| `YaraRules` | `compile(sources:) throws -> YaraRules` | Regeln kompilieren |
| `YaraScanner` | `scan(_ buffer: UnsafeRawBufferPointer, timeout:) throws -> [YaraMatch]` | Scan |

### 6.2 Datenformate der Ausgabe

`hexwerk parse --json` und `hexwerk yara --json` geben JSON aus:

```json
{ "name": "header", "type": "png_header", "offset": 0, "size": 33,
  "value": null, "children": [ { "name": "magic", "type": "bytes",
  "offset": 0, "size": 8, "value": "89504e470d0a1a0a", "children": [] } ] }
```

```json
[ { "rule": "Suspicious_UPX", "namespace": "default", "pattern": "$upx0",
    "offset": 512, "length": 4, "tags": ["packer"] } ]
```

### 6.3 CLI Interface

| Befehl | Argumente/Flags | Beschreibung |
|--------|-----------------|--------------|
| `hexwerk dump <datei>` | `--offset`, `--length`, `--width 16` | Hex-Dump eines Bereichs |
| `hexwerk inspect <datei> <offset>` | `--endian le\|be`, `--json` | Data-Inspector-Werte |
| `hexwerk find <datei> <muster>` | `--hex` (Standard), `--text`, `--encoding`, `--ignore-case`, `--int <breite>`, `--json` | Suchtreffer |
| `hexwerk diff <a> <b>` | `--json` | Unterschiedsbereiche |
| `hexwerk hash <datei>` | `--algo md5\|sha1\|sha256\|crc32`, `--offset`, `--length` | Prüfsummen |
| `hexwerk parse <datei>` | `--ksy <pfad>` oder `--format <id>`, `--json`, `--depth` | Kaitai-Parse |
| `hexwerk yara <regeln> <datei>` | `--timeout <s>`, `--json`, `-s`, `--offset`, `--length` | YARA-X-Scan |
| `hexwerk entropy <datei>` | `--offset`, `--length`, `--blocks`, `--json` | Entropie, Byte-Verteilung (FR-9.1) |
| `hexwerk script <skript.js> <datei>` | `-e`, `--write`, `--timeout` | JavaScript-Automatisierung (FR-9.2) |
| `hexwerk type <datei>` | `-e`, `--json` | Dateityp, eingebettete Dateien (FR-10.1–10.3) |
| `hexwerk strings <datei>` | `-n`, `-e`, `--json` | Zeichenketten (FR-10.4) |
| `hexwerk convert <ein> <aus>` | `--from`, `--to`, `--base`, `--fill` | bin/Intel HEX/S-Record (FR-10.6) |
| `hexwerk export <datei>` | `--format raw\|hex\|c\|python\|swift\|base64`, `--offset`, `--length`, `-o` | Bereich exportieren (FR-9.4) |
| `hexwerk open <datei>` | — | In der App öffnen |

Exit-Codes: `0` Erfolg (bei `find`/`yara` auch ohne Treffer), `1` Eingabefehler
(Datei fehlt, Offset hinter dem Ende), `2` Parse-/Kompilierfehler, `3` Timeout,
`64` falscher Aufruf (Vorgabe von swift-argument-parser).

### 6.4 External Integrations

- **YARA-X C-API** (`yara_x.h`): Kompilieren, Scanner mit Timeout, Iteration
  über passende Regeln, Patterns und Matches. Konkrete Funktionsnamen beim
  Bau der Hülle gegen den installierten Header verifizieren.
- **Kaitai-Formatsammlung**: Verzeichnisstruktur `<kategorie>/<id>.ksy`;
  `imports` werden relativ zur importierenden Datei und dann über die
  Sammlung aufgelöst.

## 7. Data Models

Alle Modelle leben im Speicher; es gibt keine Datenbank.

### 7.1 Entity: Piece

| Feld | Typ | Constraints | Beschreibung |
|------|-----|-------------|--------------|
| `source` | `.original` / `.added` | — | Herkunftspuffer |
| `start` | `UInt64` | < Pufferlänge | Start im Herkunftspuffer |
| `length` | `UInt64` | > 0 | Länge |

`PieceTable` hält eine geordnete Liste von Pieces (für schnelle
Offset-Suche als balancierter Baum mit Teillängen, assumed) und einen
Append-Puffer für neue Bytes.

### 7.2 Entity: ParseNode

| Feld | Typ | Beschreibung |
|------|-----|--------------|
| `name` | `String` | Feldname aus `seq`/`instances`, bei Arrays mit Index |
| `typeName` | `String` | Kaitai-Typ |
| `range` | `Range<UInt64>` | Bereich im (Unter-)Strom |
| `stream` | `StreamID` | Hauptdatei oder verarbeiteter Unterstrom (FR-6.6) |
| `value` | `ParseValue?` | Int, Float, String, Bytes, Enum, Bool |
| `children` | `[ParseNode]` bzw. lazy | Unterknoten |
| `error` | `ParseError?` | Fehler an diesem Knoten |

### 7.3 Entity: YaraMatch

| Feld | Typ | Beschreibung |
|------|-----|--------------|
| `rule` | `String` | Regelname |
| `namespace` | `String` | Namespace |
| `patternID` | `String` | z. B. `$a` |
| `range` | `Range<UInt64>` | Trefferbereich in der Datei |
| `tags` | `[String]` | Regel-Tags |

### 7.4 Entity: Highlight

| Feld | Typ | Beschreibung |
|------|-----|--------------|
| `range` | `Range<UInt64>` | Bereich |
| `kind` | `.kaitai` / `.yara` / `.search` / `.bookmark` / `.diff` | Quelle |
| `color` | Farbtoken | Darstellung |
| `label` | `String?` | Tooltip |

## 8. Operational Procedures

### 8.1 Local Development Setup

```bash
xcode-select --install          # Command Line Tools (vorhanden)
brew install yara-x             # C-API + yr-CLI
git clone https://git.schreck-thomas.de/ts/hexwerk.git ~/src/80_tools/hexwerk
cd ~/src/80_tools/hexwerk
make test                        # swift test
make cli                         # baut und installiert hexwerk nach ~/.local/bin
make app                         # baut hexwerk.app, signiert ad-hoc, kopiert nach /Applications
make formats                     # klont/aktualisiert kaitai_struct_formats
```

### 8.2 Konfiguration

| Einstellung | Ort | Standard | Beschreibung |
|-------------|-----|----------|--------------|
| Formatsammlung | App-Einstellungen | `~/.config/hexwerk/formats` | Kaitai-Checkout |
| Eigene Formate | App-Einstellungen | `~/.config/hexwerk/ksy` | überdecken die Sammlung |
| YARA-Timeout | App/CLI | 60 s | Scan-Abbruch |
| Speichermodus | App-Einstellungen | Ersatzdatei | in-place nur bei gleicher Länge |
| Bytes pro Zeile | App-Einstellungen | 16 | FR-2.6 |

### 8.3 Deployment

1. `make test` grün.
2. `make app` → Bundle bauen (YARA-X ist statisch gelinkt),
   `codesign --force -s -`.
3. Alte App in den Papierkorb, neue nach `/Applications`.
4. Rollback: vorherige Version aus `dist/` (letzte drei Builds aufbewahrt, assumed).

### 8.4 Monitoring

Nicht anwendbar (lokale Desktop-App). Fehler werden über `os_log`
(Subsystem `de.schreck-thomas.hexwerk`, assumed) protokolliert.

## 9. Verification & Validation

### 9.1 Phase 1 Verification

| Test ID | Feature | Vorgehen | Erfolgskriterium |
|---------|---------|----------|------------------|
| TC-1.1 | Test-Infrastruktur | `swift test` mit einem Beispieltest | läuft ohne Xcode durch (R-1 gelöst) |
| TC-1.2 | mmap-Öffnen | 10-GB-Sparse-Datei öffnen, Zeit bis erste Seite messen | < 1 s, RSS < 200 MB |
| TC-1.3 | Lesen | Zufällige Bereiche lesen, mit `dd` vergleichen | identisch |
| TC-1.4 | Schreibschutz | Edit auf schreibgeschütztem Dokument | wird abgewiesen |
| TC-1.5 | Überschreiben + Undo/Redo | Zufallsfolge von Edits, dann alles rückgängig | Inhalt = Original |
| TC-1.6 | Speichern in-place | Überschreiben, speichern, SHA-256 + `cmp -l` | nur geänderte Bytes anders |
| TC-1.7 | Speichern atomar | Speichern mit simuliertem Abbruch | Original unverändert |
| TC-1.8 | Hex-Ansicht | Scrollen an Dateianfang/-mitte/-ende einer 10-GB-Datei, Zeichenzeit messen | < 8 ms pro Seite, korrekte Offsets |
| TC-1.9 | Auswahl/Cursor | UI-Test: Auswahl in Hex, Prüfung im Zeichenbereich | synchron |
| TC-1.10 | Data Inspector | Bekannte Bytefolgen für alle Typen LE/BE | Werte wie Referenz |
| TC-1.11 | Highlights | Testbereich setzen, Ansicht rendern | Bereich farbig |
| TC-1.12 | CLI dump/inspect | Ausgabe gegen `xxd` bzw. Referenzwerte | identisch, Exit-Code 0 |
| TC-1.13 | Robustheit | Fuzzing Inspector/Dump mit Zufallsdateien und Grenzoffsets | kein Absturz |

### 9.2 Phase 2 Verification

| Test ID | Feature | Vorgehen | Erfolgskriterium |
|---------|---------|----------|------------------|
| TC-2.1 | Einfügen/Löschen | Zufallsfolge, Vergleich gegen naive `Data`-Implementierung | identisch |
| TC-2.2 | Speichern mit Längenänderung | Insert, speichern, neu öffnen | Inhalt korrekt, atomar |
| TC-2.3 | Kopieren/Einfügen | Hex-Text und Rohbytes | korrekt |
| TC-2.4 | Gehe-zu | absolute/relative, hex/dezimal | Cursor korrekt |
| TC-2.5 | Hex-Suche mit Wildcards | Muster mit `??` in Testdatei | alle Treffer, keine falschen |
| TC-2.6 | Textsuche | ASCII/UTF-8/UTF-16, Groß/klein | alle Treffer |
| TC-2.7 | Abbruch/Fortschritt | Suche über 10 GB abbrechen | stoppt < 200 ms |
| TC-2.8 | Suchgeschwindigkeit | 1 GB Zufallsdaten, Byte-Muster | ≥ 500 MB/s |
| TC-2.9 | Ersetzen | Ersetzen einzeln/alle, Undo | korrekt |
| TC-2.10 | Diff | Dateien mit bekannten Unterschieden | alle Bereiche gefunden |
| TC-2.11 | Hashes | gegen `shasum`, `md5`, `crc32` | identisch |
| TC-2.12 | Externe Änderung | Datei extern ändern, dann speichern | Warnung erscheint |
| TC-2.13 | Mehrere Dokumente | zwei Dateien öffnen, unabhängig bearbeiten | getrennt |
| TC-2.14 | Füllen/Lesezeichen/Zahlensuche | Bereich füllen, Lesezeichen anlegen, int32 suchen | korrekt |

### 9.3 Phase 3 und 4 Verification

| Test ID | Feature | Vorgehen | Erfolgskriterium |
|---------|---------|----------|------------------|
| TC-3.1 | Referenzformate | Referenzliste (11.2) gegen Testdateien parsen, JSON mit Python-Runtime vergleichen | alle Feldwerte gleich |
| TC-3.2 | Ausdruckssprache | Tabelle aus Ausdrücken mit erwarteten Werten | alle korrekt |
| TC-3.3 | Repeat/Switch/Instances | Synthetische `.ksy` je Konstrukt | korrekt |
| TC-3.4 | Process-Routinen | zlib/xor/rol-Testdaten | Unterstrom korrekt |
| TC-3.5 | Bit-Felder | Synthetische `.ksy` mit `b1`…`b12` | korrekt |
| TC-3.6 | Fehlerfall | Abgeschnittene PNG | Teilbaum + Fehler mit Offset/Pfad |
| TC-3.7 | Grenzen | Rekursive `.ksy`, riesige Repeat-Zahl | sauberer Abbruch, kein Absturz |
| TC-3.8 | Baum ↔ Hex | UI: Knoten wählen, Bereich prüfen; Byte klicken, Knoten prüfen | synchron |
| TC-3.9 | Auto-Format, Imports, eigene Formate | `.png` öffnen; Format mit Import; eigenes Format gleichen Namens | richtig vorgeschlagen/aufgelöst/überdeckt |
| TC-3.10 | Lazy Arrays | Format mit 10⁶ Elementen | Baum sofort bedienbar |
| TC-3.11 | CLI parse | `hexwerk parse --json` | gültiges JSON gemäß 6.2 |
| TC-4.1 | Kompilieren | gültige und fehlerhafte Regeln | Erfolg bzw. Fehler mit Zeile |
| TC-4.2 | Scan | Testkorpus, Vergleich mit `yr scan -s` | gleiche Regeln und Offsets |
| TC-4.3 | Auswahl-Scan | Treffer in Auswahl | Offsets auf Datei umgerechnet |
| TC-4.4 | Timeout/Abbruch | Regel mit hoher Laufzeit | bricht ab, Exit-Code 3 im CLI |
| TC-4.5 | Geändertes Dokument | Bytes ändern, scannen | Treffer entsprechen geändertem Inhalt |
| TC-4.6 | Markierungen | Treffer in der Ansicht | farbig markiert |
| TC-4.7 | CLI yara | `hexwerk yara --json` | gültiges JSON gemäß 6.2 |
| TC-5.1 | Entropie | konstante/gleichverteilte Blöcke, geänderter Inhalt, Teilbereich, Abbruch | 0 bzw. 8 Bit/Byte, Änderungen sichtbar |
| TC-5.2 | Skripte | Lese-API, Schreiben als ein Undo-Schritt, Fehler mit Zeile und Rollback, Zeitlimit, Abbruch, Schreibschutz, Arbeitskopie übernehmen | wie erwartet |
| TC-6.1 | Dateityp | erzeugte PNG/GIF/BMP/JPEG/TIFF/gzip/ELF/SQLite, CAFEBABE-Fall, eingebettete Dateien, 4 MiB Zufall, libmagic | richtig erkannt, < 10 Fehltreffer |
| TC-6.2 | Prüfsummen | CRC-Katalog-Prüfwerte, Vektoren, BLAKE3-Baum, Python hashlib an Blockgrenzen, ein Durchlauf = einzeln | identisch |
| TC-6.3 | Strings/Regex | ASCII/UTF-8/UTF-16 an ungeraden Offsets, Blockgrenzen, Regex über Bytes | wie erwartet |
| TC-6.4 | Intel HEX/S-Record | Referenzbeispiele, Fehler mit Zeile, Rundreise mit Lücken und 64-KiB-Grenze | identisch |
| TC-6.5 | Projekte | Speichern/Laden, Pfadschreibweisen, kaputte Dateien | wie erwartet |
| TC-6.6 | Rechner | Vorrang, Basen, Vorzeichen, Überlauf, Fehler, Variablen, Darstellungen | wie erwartet |
| TC-6.7 | Vim | Bewegungen mit Zähler, Modi, Bearbeiten, Marken | wie erwartet |
| TC-5.4 | Export | alle Formate; Python-Ausgabe von python3 eingelesen | identische Bytes |

### 9.4 Acceptance Tests

- Firmware-Image (einige hundert MB) öffnen, ELF-Header per Kaitai lesen,
  YARA-Regel für einen bekannten String trifft, Byte ändern, speichern,
  Prüfsumme mit `shasum` bestätigen.
- Zwei Wochen ausschließlich hexwerk als Hex-Editor nutzen; jede Lücke wird
  als Anforderung (Issue) erfasst.

### 9.5 Traceability Matrix

| Requirement | Priority | Test Case(s) | Status |
|-------------|----------|--------------|--------|
| FR-1.1 | Must | TC-1.2, TC-1.3 | Covered |
| FR-1.2 | Must | TC-1.4 | Covered |
| FR-1.3 | Must | TC-1.6 | Covered |
| FR-1.4 | Must | TC-1.7, TC-2.2 | Covered |
| FR-1.5 | Must | TC-2.2 | Covered |
| FR-1.6 | Should | TC-2.12 | Covered |
| FR-1.7 | Should | TC-2.13 | Covered |
| FR-1.8 | May | --- | Not required |
| FR-2.1 | Must | TC-1.8 | Covered |
| FR-2.2 | Must | TC-1.8 | Covered |
| FR-2.3 | Must | TC-1.9 | Covered |
| FR-2.4 | Must | TC-1.5, TC-1.9 | Covered |
| FR-2.5 | Must | TC-1.11 | Covered |
| FR-2.6 | Should | --- | GAP |
| FR-2.7 | Should | --- | GAP |
| FR-2.8 | Should | --- | GAP |
| FR-2.9 | Must | TC-1.11, TC-3.8, TC-4.6 | Covered |
| FR-3.1 | Must | TC-1.5, TC-2.9 | Covered |
| FR-3.2 | Must | TC-2.1 | Covered |
| FR-3.3 | Must | TC-2.3 | Covered |
| FR-3.4 | Should | TC-2.14 | Covered |
| FR-3.5 | Must | TC-2.4 | Covered |
| FR-3.6 | Should | TC-2.14 | Covered |
| FR-4.1 | Must | TC-1.10 | Covered |
| FR-4.2 | Must | TC-1.10 | Covered |
| FR-4.3 | Should | TC-1.10 | Covered |
| FR-4.4 | Should | TC-1.10 | Covered |
| FR-4.5 | Should | TC-1.10 | Covered |
| FR-4.6 | Should | InspectorEditTests | Covered |
| FR-5.1 | Must | TC-2.5 | Covered |
| FR-5.2 | Must | TC-2.6 | Covered |
| FR-5.3 | Should | TC-2.14 | Covered |
| FR-5.4 | Must | TC-2.5, TC-2.6 | Covered |
| FR-5.5 | Should | TC-2.9 | Covered |
| FR-5.6 | Must | TC-2.7 | Covered |
| FR-5.7 | Should | TC-2.10 | Covered |
| FR-5.8 | Should | TC-2.11 | Covered |
| FR-6.1 | Must | TC-3.1 | Covered |
| FR-6.2 | Must | TC-3.1, TC-3.3 | Covered |
| FR-6.3 | Must | TC-3.3 | Covered |
| FR-6.4 | Must | TC-3.3 | Covered |
| FR-6.5 | Must | TC-3.2 | Covered |
| FR-6.6 | Should | TC-3.4 | Covered |
| FR-6.7 | Should | TC-3.5 | Covered |
| FR-6.8 | Must | TC-3.8 | Covered |
| FR-6.9 | Must | TC-3.6 | Covered |
| FR-6.10 | Should | TC-3.9 | Covered |
| FR-6.11 | Should | TC-3.9 | Covered |
| FR-6.12 | Should | TC-3.9 | Covered |
| FR-6.13 | Should | TC-3.10 | Covered |
| FR-7.1 | Must | TC-4.1 | Covered |
| FR-7.2 | Must | TC-4.2 | Covered |
| FR-7.3 | Should | TC-4.3 | Covered |
| FR-7.4 | Must | TC-4.2, TC-4.6 | Covered |
| FR-7.5 | Must | TC-4.4 | Covered |
| FR-7.6 | Should | TC-4.5 | Covered |
| FR-7.7 | May | TC-4.2 | Covered |
| FR-8.1 | Must | TC-1.12 | Covered |
| FR-8.2 | Must | TC-1.12 | Covered |
| FR-8.3 | Should | CLITests | Covered |
| FR-8.4 | Should | CLITests | Covered |
| FR-8.5 | Must | TC-3.11 | Covered |
| FR-8.6 | Must | TC-4.7 | Covered |
| FR-8.7 | Must | TC-1.12, TC-4.4 | Covered |
| FR-8.8 | Should | CLITests (Fehlerfälle), manuell (App öffnet Datei) | Covered |
| FR-9.1 | May | TC-5.1 | Covered |
| FR-9.2 | May | TC-5.2 | Covered |
| FR-9.3 | May | --- | Removed |
| FR-9.4 | May | TC-5.4 | Covered |
| FR-10.1 | Should | TC-6.1 | Covered |
| FR-10.2 | Should | TC-6.1 | Covered |
| FR-10.3 | Should | TC-6.1 | Covered |
| FR-10.4 | Should | TC-6.3 | Covered |
| FR-10.5 | Should | TC-6.3 | Covered |
| FR-10.6 | Should | TC-6.4 | Covered |
| FR-10.7 | Should | TC-6.5 | Covered |
| FR-10.8 | Should | TC-6.6 | Covered |
| FR-10.9 | May | TC-6.7 | Covered (Tastenlogik; App-Teil ungeprüft) |
| FR-10.10 | Should | TC-6.2 | Covered |
| FR-10.11 | Should | AlignedDiffTests | Covered |
| FR-11.1 | Should | PixelTests | Covered |
| NFR-1.1 | Must | TC-1.2 | Covered |
| NFR-1.2 | Must | TC-1.8 | Covered |
| NFR-1.3 | Must | TC-1.2 | Covered |
| NFR-1.4 | Should | TC-2.8 | Covered |
| NFR-2.1 | Must | TC-1.13, TC-3.6 | Covered |
| NFR-2.2 | Must | TC-3.7 | Covered |
| NFR-2.3 | Must | --- | GAP |
| NFR-2.4 | Must | TC-1.7 | Covered |
| NFR-3.1 | Must | TC-1.1 (Build-Prüfung) | Covered |
| NFR-3.2 | Must | alle TC | Covered |
| NFR-3.3 | Should | TC-1.1 | Covered |
| NFR-4.1 | Should | --- | GAP |
| NFR-4.2 | May | --- | Not required |

Offene Lücken (GAP): FR-2.6, FR-2.7, FR-2.8,
NFR-2.3, NFR-4.1 — Testfälle beim Umsetzen der jeweiligen Phase ergänzen.
NFR-2.3 (kein Netzwerk) lässt sich z. B. über Little Snitch oder eine
Prüfung der gelinkten Frameworks belegen.

## 10. Troubleshooting Guide

| Symptom | Wahrscheinliche Ursache | Diagnose | Abhilfe |
|---------|-------------------------|----------|---------|
| `swift test`: „plugin for module 'TestingMacros' not found“ | Compiler sucht das Plugin nicht im Unterordner (R-1) | `ls /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing` | `-plugin-path` im Test-Target prüfen (Pfad nach CLT-Update) |
| Test-Prozess endet mit `EXC_GUARD` in `thread_set_exception_ports` | wasmtime (YARA-X) im Apple-signierten Test-Runner | Backtrace zeigt `wasmtime…machports` | YARA-Scans im Test nur über das CLI aufrufen |
| Gatekeeper blockiert die App | ad-hoc-Signatur, Quarantäne-Attribut nach Kopie | `xattr -l`, `spctl -a -vv` | lokal gebaut hat keine Quarantäne; sonst `xattr -d com.apple.quarantine` |
| Build: `yara_x.h` oder `libyara_x_capi.a` nicht gefunden | `yara-x` nicht installiert | `ls /opt/homebrew/include/yara_x.h /opt/homebrew/lib/libyara_x_capi.a` | `brew install yara-x` |
| Scrollen springt bei großen Dateien | Pixel-basierte Scrollposition (R-2) | Offset am Dateiende prüfen | virtuelle Scrollposition |
| Kaitai-Parse bricht mit Limit ab | Rekursions-/Knotengrenze (NFR-2.2) | Fehlermeldung zeigt Limit | Limit in Einstellungen erhöhen |
| YARA-Treffer weichen von `yr` ab | geändertes Dokument gescannt oder andere YARA-X-Version | `yr --version`, Dokument speichern | Versionen angleichen |

## 11. Appendix

### 11.1 Standardwerte

- Bytes pro Zeile: 16; Offset-Darstellung: hex, 8 Stellen (wächst bei > 4 GB).
- Kaitai-Limits: Rekursionstiefe 256, Knoten 1 000 000, Laufzeit 30 s (assumed).
- YARA-Timeout: 60 s.
- Undo: unbegrenzt bis Speicher knapp; Warnung ab 1 GB Append-Puffer (assumed).

### 11.2 Kaitai-Referenzformate (Exit-Kriterium Phase 3)

`png`, `zip`, `elf`, `microsoft_pe`, `gif`, `bmp`, `wav`, `gzip`,
`ext2`, `pcap` — decken Endianness, Switches, Instances, Repeats, Strings
und `process: zlib` ab.

### 11.3 Glossar

- **Piece Table**: Datenstruktur, die eine Datei als Folge von Stücken aus
  Original- und Zusatzpuffer beschreibt; Bearbeitungen kopieren keine Daten.
- **Kaitai Struct**: deklarative Sprache (YAML) zur Beschreibung binärer
  Formate; `.ksy`-Dateien.
- **YARA-X**: Neuimplementierung von YARA in Rust durch VirusTotal, mit C-API.
- **Ad-hoc-Signatur**: Codesignatur ohne Entwicklerzertifikat (`codesign -s -`).
