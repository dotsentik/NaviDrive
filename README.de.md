# NaviDrive

<p align="center"><img src="docs/screenshots/navidrive-hero.png" alt="NaviDrive: Google Drive- und Dropbox-Client für macOS" width="880"></p>

<p align="center">Ein nativer macOS-Client für Google Drive und Dropbox, ausgelegt auf schnelle, fortsetzbare Downloads und Uploads großer Dateien und Ordner.</p>

Ein nativer macOS-Client für Google Drive und Dropbox, ausgelegt auf schnelle, fortsetzbare Downloads und Uploads großer Dateien und Ordner.

[English version](README.md)

## Funktionen

- Google Drive („Meine Ablage“, „Für mich freigegeben“) und Dropbox durchsuchen; mehrere Clouds gleichzeitig verbunden.
- Download-Manager: parallele Downloads in Teilstücken mit adaptiver Parallelität, Pausieren und Fortsetzen, Fortschritt bleibt nach Neustarts, Netzwerkausfällen und getrennten Laufwerken erhalten.
- Prüfsummenkontrolle nach dem Download (MD5 für Google Drive, Content-Hash für Dropbox).
- Download in einen Standardordner, einen eigenen Ordner oder auf ein externes Laufwerk; feste Speicherorte pro Cloud-Ordner; Prüfung des freien Speicherplatzes vor dem Download.
- Zeigt an, welche Cloud-Dateien bereits auf diesen Mac heruntergeladen wurden.
- Upload-Manager mit fortsetzbaren Uploads; „Upload to NaviDrive“ im Dienste-Menü des Finders.
- Dateien und Ordner per Link hinzufügen (Google Drive-Link oder -ID, Dropbox-Freigabelink).
- Ordnergrößen berechnen, neuer Ordner, verschieben, in den Papierkorb legen.
- Berücksichtigt die täglichen Übertragungslimits von Google Drive und setzt Übertragungen automatisch fort, sobald sie zurückgesetzt werden.
- Status in der Menüleiste, optional „Mac während Übertragungen wach halten“, „Beenden, wenn fertig“, ⌘Q gedrückt halten zum Beenden.
- Updates in der App über GitHub Releases: wöchentliche oder manuelle Prüfung; der Download wird vor der Installation überprüft (SHA-256, Signaturzertifikat, Version).
- Oberfläche auf Englisch und Russisch.

## Voraussetzungen

- macOS 15 oder neuer.
- Apple silicon oder Intel: die von `Scripts/release.sh` erstellten Release-DMGs sind universell (`arm64` + `x86_64`); ein einfacher lokaler Build ist nur `arm64`.
- Zum Bauen: Xcode 16 oder neuer und [XcodeGen](https://github.com/yonaskolb/XcodeGen).

## Installation

Lade `NaviDrive-X.Y.Z.dmg` von [GitHub Releases](https://github.com/dotsentik/NaviDrive/releases) herunter, öffne es und ziehe NaviDrive in den Ordner „Programme“. Lies vor dem ersten Öffnen den Abschnitt [Erster Start](#erster-start).

## Erster Start

Release-Builds sind mit dem eigenen Zertifikat des Projekts signiert und nicht von Apple notarisiert, deshalb blockiert Gatekeeper auf einem anderen Mac den ersten Start aus dem DMG.

1. Ziehe NaviDrive in „Programme“, klicke dann mit der rechten Maustaste darauf → „Öffnen“ → „Öffnen“.
2. Falls das nicht hilft, führe im Terminal aus:
   `xattr -dr com.apple.quarantine /Applications/NaviDrive.app`
3. Wenn das DMG über einen Messenger mit Sandbox (zum Beispiel Telegram) kam und macOS „File created by an AppSandbox“ meldet, führe aus:
   `sudo xattr -cr /Applications/NaviDrive.app`

Lade das DMG im Browser von GitHub Releases herunter oder sende es per AirDrop, um Schritt 3 zu vermeiden.

Diese Schritte sind nur einmal nötig. Updates, die in der App installiert werden (NaviDrive → Check for Updates…), brauchen sie nicht.

## Aus dem Quellcode bauen

```sh
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig   # then fill in the values, see below
xcodegen generate
xcodebuild -project NaviDrive.xcodeproj -scheme NaviDrive -configuration Release \
  -derivedDataPath ./DerivedData -quiet build
Scripts/make_dmg.sh   # ~/Desktop/NaviDrive-<version>.dmg
```

Releases werden mit `Scripts/release.sh X.Y.Z` aus einem sauberen `main` erstellt: Das Skript baut eine universelle App, prüft das Signaturzertifikat gegen `Config/signing-fingerprint.txt`, erstellt `NaviDrive-X.Y.Z.dmg` und `NaviDrive-X.Y.Z.dmg.sha256`, übernimmt die Versionshinweise aus `CHANGELOG.md` und veröffentlicht sie mit `gh`. `Scripts/release.sh --dry-run X.Y.Z` baut und prüft die Dateien, ohne sie zu veröffentlichen.

`NaviDrive.xcodeproj` wird aus `project.yml` generiert; ändere Build-Einstellungen dort, nicht im Xcode-Projekt.

Release-Builds werden mit dem Zertifikat „NaviDrive Signing“ signiert. Wenn es nicht in deinem Schlüsselbund ist, ändere für einen lokalen Build `CODE_SIGN_IDENTITY` in `project.yml`. Mit einem anderen Zertifikat signierte Kopien können keine Kopien aktualisieren, die mit dem Originalzertifikat signiert sind; siehe [docs/SIGNING.md](docs/SIGNING.md).

## OAuth-Konfiguration

Cloud-Zugangsdaten werden nicht im Repository gespeichert. `Config/NaviDrive.xcconfig` bindet die nicht versionierte Datei `Config/Secrets.xcconfig` ein; ihre Werte gelangen als `$(GOOGLE_CLIENT_ID)`, `$(GOOGLE_CLIENT_SECRET)` und `$(DROPBOX_APP_KEY)` in die `Info.plist`.

- **Google Drive**: Erstelle in der Google Cloud Console einen OAuth-Client vom Typ „Desktop app“ mit aktivierter Drive API und trage seine Client ID und sein Client Secret in `Config/Secrets.xcconfig` ein. Ohne sie hat der Build keine integrierte Google-Anmeldung, und Nutzer geben in den Einstellungen ihre eigene Client ID und ihr eigenes Client Secret ein (gespeichert im Schlüsselbund).
- **Dropbox**: Erstelle eine App unter dropbox.com/developers/apps, füge die Redirect-URI `http://127.0.0.1:53682/callback` hinzu und trage ihren App key in `DROPBOX_APP_KEY` ein. Ohne ihn ist die Dropbox-Anmeldung nicht verfügbar.

## Sicherheit und Datenschutz

- OAuth-Tokens und vom Nutzer eingegebene Zugangsdaten werden im macOS-Schlüsselbund gespeichert.
- Die App kommuniziert nur mit Google (accounts.google.com, oauth2.googleapis.com, www.googleapis.com) und Dropbox (dropbox.com, api.dropboxapi.com, content.dropboxapi.com) sowie bei der Suche nach Updates mit GitHub (api.github.com und dessen Download-Hosts für Releases). Es gibt keine Analyse- oder Telemetriedaten.
- Die Anmeldung nutzt einen lokalen Loopback-Server auf 127.0.0.1, um die OAuth-Antwort zu empfangen.
- Warteschlange, Verlauf und Ordnergrößen werden in einer lokalen SQLite-Datenbank in `~/Library/Application Support/NaviDrive` gespeichert.

## Aufbau des Repositorys

```
Sources/
  API/        Google Drive and Dropbox API clients and providers
  App/        app entry point, AppModel and its extensions
  Auth/       OAuth, loopback server, token management
  Cloud/      cloud-agnostic item and provider types
  Download/   download scheduler, workers, chunk writing, verification
  Upload/     upload planner, scheduler, workers
  Update/     update check, verification and installation
  Storage/    SQLite database, settings, Keychain
  Models/     shared models and formatters
  Views/      SwiftUI views
Resources/    asset catalog, localization (en, ru), design sources
Support/      Info.plist
Config/       xcconfig files, signing fingerprint
Scripts/      release, DMG and icon tooling
Tests/        unit tests (update logic)
docs/         signing and maintenance documentation
project.yml   XcodeGen project definition
```

## Lizenz

MIT, siehe die Datei [LICENSE](LICENSE).

<sub>Diese Übersetzung wurde mit KI erstellt – Korrekturen sind in den [Issues](https://github.com/dotsentik/NaviDrive/issues) willkommen.</sub>
