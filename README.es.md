<p align="center"><a href="README.md">English</a> · <a href="README.ru.md">Русский</a> · <a href="README.uk.md">Українська</a> · <a href="README.de.md">Deutsch</a> · <b>Español</b> · <a href="README.hi.md">हिन्दी</a> · <a href="README.el.md">Ελληνικά</a></p>

# NaviDrive

<p align="center"><img src="docs/screenshots/navidrive-hero.png" alt="NaviDrive: cliente de Google Drive y Dropbox para macOS" width="880"></p>

<p align="center">Un cliente nativo de Google Drive y Dropbox para macOS, centrado en descargas y subidas rápidas y reanudables de archivos y carpetas grandes.</p>

Un cliente nativo de Google Drive y Dropbox para macOS, centrado en descargas y subidas rápidas y reanudables de archivos y carpetas grandes.

## Funciones

- Explora Google Drive («Mi unidad», «Compartido conmigo») y Dropbox; varias nubes conectadas a la vez.
- Gestor de descargas: descargas paralelas por fragmentos con concurrencia adaptativa, pausa y reanudación, y un progreso que se conserva tras reinicios, cortes de red y discos desconectados.
- Verificación de la suma de comprobación tras la descarga (MD5 para Google Drive, content hash para Dropbox).
- Descarga en una carpeta predeterminada, en una carpeta personalizada o en un disco externo; ubicaciones de guardado permanentes para cada carpeta de la nube; comprobación del espacio libre antes de descargar.
- Muestra qué archivos de la nube ya están descargados en este Mac.
- Gestor de subidas con subidas reanudables; «Upload to NaviDrive» en el menú Servicios del Finder.
- Añade archivos y carpetas mediante un enlace (enlace o ID de Google Drive, enlace compartido de Dropbox).
- Cálculo del tamaño de carpetas, nueva carpeta, mover, mover a la Papelera.
- Tiene en cuenta los límites diarios de transferencia de Google Drive y reanuda las transferencias automáticamente cuando se restablecen.
- Estado en la barra de menús, opción de «mantener el Mac activo durante las transferencias», «Salir al terminar», mantener pulsado ⌘Q para salir.
- Actualizaciones dentro de la app desde GitHub Releases: comprobación semanal o manual; la descarga se verifica (SHA-256, certificado de firma, versión) antes de instalarla.
- Interfaz en inglés y ruso.

## Requisitos

- macOS 15 o posterior.
- Apple silicon o Intel: los DMG de las versiones creados con `Scripts/release.sh` son universales (`arm64` + `x86_64`); una compilación local normal es solo `arm64`.
- Para compilar: Xcode 16 o posterior y [XcodeGen](https://github.com/yonaskolb/XcodeGen).

## Instalación

Descarga `NaviDrive-X.Y.Z.dmg` desde [GitHub Releases](https://github.com/dotsentik/NaviDrive/releases), ábrelo y arrastra NaviDrive a Aplicaciones. Consulta [Primer inicio](#primer-inicio) antes de abrirlo por primera vez.

## Primer inicio

Las versiones publicadas están firmadas con el certificado propio del proyecto y no están notarizadas por Apple, así que en otro Mac Gatekeeper bloquea el primer inicio desde el DMG.

1. Arrastra NaviDrive a Aplicaciones y luego haz clic derecho sobre la app → Abrir → Abrir.
2. Si eso no funciona, ejecuta en Terminal:
   `xattr -dr com.apple.quarantine /Applications/NaviDrive.app`
3. Si el DMG llegó a través de una app de mensajería con sandbox (por ejemplo, Telegram) y macOS muestra «File created by an AppSandbox», ejecuta:
   `sudo xattr -cr /Applications/NaviDrive.app`

Descarga el DMG desde GitHub Releases en un navegador o envíalo por AirDrop para evitar el paso 3.

Estos pasos solo son necesarios una vez. Las actualizaciones instaladas desde la propia app (NaviDrive → Check for Updates…) no los necesitan.

## Compilar desde el código fuente

```sh
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig   # then fill in the values, see below
xcodegen generate
xcodebuild -project NaviDrive.xcodeproj -scheme NaviDrive -configuration Release \
  -derivedDataPath ./DerivedData -quiet build
Scripts/make_dmg.sh   # ~/Desktop/NaviDrive-<version>.dmg
```

Las versiones se publican con `Scripts/release.sh X.Y.Z` desde una rama `main` limpia: el script compila una app universal, comprueba el certificado de firma con `Config/signing-fingerprint.txt`, crea `NaviDrive-X.Y.Z.dmg` y `NaviDrive-X.Y.Z.dmg.sha256`, toma las notas de la versión de `CHANGELOG.md` y las publica con `gh`. `Scripts/release.sh --dry-run X.Y.Z` compila y comprueba los archivos sin publicarlos.

`NaviDrive.xcodeproj` se genera a partir de `project.yml`; cambia los ajustes de compilación allí, no en el proyecto de Xcode.

Las versiones publicadas se firman con el certificado «NaviDrive Signing». Si no lo tienes en tu llavero, cambia `CODE_SIGN_IDENTITY` en `project.yml` para una compilación local. Las copias firmadas con otro certificado no pueden actualizar las copias firmadas con el original; consulta [docs/SIGNING.md](docs/SIGNING.md).

## Configuración de OAuth

Las credenciales de la nube no se guardan en el repositorio. `Config/NaviDrive.xcconfig` incluye el archivo no versionado `Config/Secrets.xcconfig`; sus valores llegan a `Info.plist` como `$(GOOGLE_CLIENT_ID)`, `$(GOOGLE_CLIENT_SECRET)` y `$(DROPBOX_APP_KEY)`.

- **Google Drive**: crea en Google Cloud Console un cliente OAuth de tipo «Desktop app» con la Drive API habilitada y pon su Client ID y su Client Secret en `Config/Secrets.xcconfig`. Sin ellos, la compilación no incluye un inicio de sesión de Google integrado y los usuarios introducen su propio Client ID y Client Secret en Ajustes (se guardan en el llavero).
- **Dropbox**: crea una app en dropbox.com/developers/apps, añade la URI de redirección `http://127.0.0.1:53682/callback` y pon su App key en `DROPBOX_APP_KEY`. Sin ella, el inicio de sesión en Dropbox no está disponible.

## Seguridad y privacidad

- Los tokens de OAuth y las credenciales que introduce el usuario se guardan en el llavero de macOS.
- La app solo se comunica con Google (accounts.google.com, oauth2.googleapis.com, www.googleapis.com) y Dropbox (dropbox.com, api.dropboxapi.com, content.dropboxapi.com), y con GitHub (api.github.com y sus servidores de descarga de versiones) al buscar actualizaciones. No hay analítica ni telemetría.
- El inicio de sesión usa un servidor loopback local en 127.0.0.1 para recibir la respuesta de OAuth.
- La cola, el historial y los tamaños de carpetas se guardan en una base de datos SQLite local en `~/Library/Application Support/NaviDrive`.

## Estructura del repositorio

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

## Licencia

MIT, consulta el archivo [LICENSE](LICENSE).

<sub>Traducción hecha con ayuda de IA: las correcciones son bienvenidas en [issues](https://github.com/dotsentik/NaviDrive/issues).</sub>
