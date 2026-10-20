<p align="center"><a href="README.md">English</a> · <b>Русский</b> · <a href="README.uk.md">Українська</a> · <a href="README.de.md">Deutsch</a> · <a href="README.es.md">Español</a> · <a href="README.hi.md">हिन्दी</a> · <a href="README.el.md">Ελληνικά</a></p>

# NaviDrive

<p align="center"><img src="docs/screenshots/navidrive-hero.png" alt="NaviDrive: клиент Google Drive и Dropbox для macOS" width="880"></p>

<p align="center">Нативный клиент Google Drive и Dropbox для macOS для быстрого скачивания и отправки больших файлов и папок с докачкой.</p>

Нативный клиент Google Drive и Dropbox для macOS для быстрого скачивания и отправки больших файлов и папок с докачкой.

## Возможности

- Просмотр Google Drive («Мой Диск», «Доступные мне») и Dropbox; можно подключить несколько облаков одновременно.
- Менеджер загрузок: параллельное скачивание частями с адаптивным числом потоков, пауза и продолжение, прогресс сохраняется после перезапуска, обрыва сети и отключения диска.
- Проверка контрольной суммы после скачивания (MD5 для Google Drive, content hash для Dropbox).
- Скачивание в папку по умолчанию, в выбранную папку или на внешний диск; постоянные места сохранения для папок в облаке; проверка свободного места перед скачиванием.
- Показывает, какие файлы из облака уже скачаны на этот Mac.
- Менеджер отправки с докачкой; пункт «Upload to NaviDrive» в меню «Службы» Finder.
- Добавление файлов и папок по ссылке (ссылка или ID Google Drive, общая ссылка Dropbox).
- Подсчёт размера папок, создание папки, перемещение, перемещение в Корзину.
- Учитывает дневные лимиты передачи Google Drive и автоматически продолжает передачу после их сброса.
- Статус в строке меню, необязательный режим «Не давать Mac засыпать во время загрузок и отправки», «Выйти после завершения», выход удержанием ⌘Q.
- Обновления внутри приложения из GitHub Releases: проверка раз в неделю или вручную; перед установкой загрузка проверяется (SHA-256, сертификат подписи, версия).
- Интерфейс на английском и русском.

## Требования

- macOS 15 или новее.
- Apple silicon или Intel: релизные DMG, собранные `Scripts/release.sh`, универсальные (`arm64` + `x86_64`); обычная локальная сборка — только `arm64`.
- Для сборки: Xcode 16 или новее и [XcodeGen](https://github.com/yonaskolb/XcodeGen).

## Установка

Скачайте `NaviDrive-X.Y.Z.dmg` из [GitHub Releases](https://github.com/dotsentik/NaviDrive/releases), откройте его и перетащите NaviDrive в «Программы». Перед первым запуском прочитайте раздел [Первый запуск](#первый-запуск).

## Первый запуск

Релизные сборки подписаны собственным сертификатом проекта и не нотаризованы Apple, поэтому на другом Mac Gatekeeper блокирует первый запуск из DMG.

1. Перетащите NaviDrive в «Программы», затем правый клик → «Открыть» → «Открыть».
2. Если это не помогло, выполните в Терминале:
   `xattr -dr com.apple.quarantine /Applications/NaviDrive.app`
3. Если DMG пришёл через мессенджер с песочницей (например, Telegram) и macOS пишет «File created by an AppSandbox», выполните:
   `sudo xattr -cr /Applications/NaviDrive.app`

Чтобы шаг 3 не понадобился, скачивайте DMG из GitHub Releases в браузере или передавайте его по AirDrop.

Эти шаги нужны только один раз. Обновлениям, установленным из самого приложения (NaviDrive → «Проверить обновления…»), они не нужны.

## Сборка из исходников

```sh
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig   # then fill in the values, see below
xcodegen generate
xcodebuild -project NaviDrive.xcodeproj -scheme NaviDrive -configuration Release \
  -derivedDataPath ./DerivedData -quiet build
Scripts/make_dmg.sh   # ~/Desktop/NaviDrive-<version>.dmg
```

Релизы выпускаются командой `Scripts/release.sh X.Y.Z` из чистой ветки `main`: скрипт собирает универсальное приложение, сверяет сертификат подписи с `Config/signing-fingerprint.txt`, создаёт `NaviDrive-X.Y.Z.dmg` и `NaviDrive-X.Y.Z.dmg.sha256`, берёт заметки к релизу из `CHANGELOG.md` и публикует всё через `gh`. `Scripts/release.sh --dry-run X.Y.Z` собирает и проверяет файлы без публикации.

`NaviDrive.xcodeproj` генерируется из `project.yml`; настройки сборки меняйте там, а не в проекте Xcode.

Релизные сборки подписываются сертификатом «NaviDrive Signing». Если его нет в вашей Связке ключей, для локальной сборки измените `CODE_SIGN_IDENTITY` в `project.yml`. Копии, подписанные другим сертификатом, не могут обновить копии, подписанные исходным; подробнее — в [docs/SIGNING.md](docs/SIGNING.md).

## Настройка OAuth

Учётные данные облаков в репозитории не хранятся. `Config/NaviDrive.xcconfig` подключает неотслеживаемый `Config/Secrets.xcconfig`; его значения попадают в `Info.plist` как `$(GOOGLE_CLIENT_ID)`, `$(GOOGLE_CLIENT_SECRET)` и `$(DROPBOX_APP_KEY)`.

- **Google Drive**: создайте в Google Cloud Console OAuth-клиент типа «Desktop app» с включённым Drive API и впишите его Client ID и Client Secret в `Config/Secrets.xcconfig`. Без них в сборке нет встроенного входа в Google, и пользователи вводят собственные Client ID и Client Secret в настройках (они хранятся в Связке ключей).
- **Dropbox**: создайте приложение на dropbox.com/developers/apps, добавьте redirect URI `http://127.0.0.1:53682/callback` и впишите его App key в `DROPBOX_APP_KEY`. Без него вход в Dropbox недоступен.

## Безопасность и конфиденциальность

- OAuth-токены и введённые пользователем учётные данные хранятся в Связке ключей macOS.
- Приложение обращается только к Google (accounts.google.com, oauth2.googleapis.com, www.googleapis.com) и Dropbox (dropbox.com, api.dropboxapi.com, content.dropboxapi.com), а при проверке обновлений — к GitHub (api.github.com и его серверам для скачивания релизов). Аналитики и телеметрии нет.
- Для входа используется локальный loopback-сервер на 127.0.0.1, который принимает ответ OAuth.
- Очередь, история и размеры папок хранятся в локальной базе SQLite в `~/Library/Application Support/NaviDrive`.

## Структура репозитория

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

## Лицензия

MIT, см. файл [LICENSE](LICENSE).
