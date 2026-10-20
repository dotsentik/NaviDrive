<p align="center"><a href="README.md">English</a> · <a href="README.ru.md">Русский</a> · <b>Українська</b> · <a href="README.de.md">Deutsch</a> · <a href="README.es.md">Español</a> · <a href="README.hi.md">हिन्दी</a> · <a href="README.el.md">Ελληνικά</a></p>

# NaviDrive

<p align="center"><img src="docs/screenshots/navidrive-hero.png" alt="NaviDrive: клієнт Google Drive і Dropbox для macOS" width="880"></p>

<p align="center">Нативний клієнт Google Drive і Dropbox для macOS для швидкого завантаження та вивантаження великих файлів і папок із докачуванням.</p>

## Можливості

- Перегляд Google Drive («Мій диск», «Доступні мені») і Dropbox; можна підключити кілька хмар одночасно.
- Менеджер завантажень: паралельне завантаження частинами з адаптивною кількістю потоків, пауза й продовження, прогрес зберігається після перезапуску, обриву мережі та від'єднання диска.
- Перевірка контрольної суми після завантаження (MD5 для Google Drive, content hash для Dropbox).
- Завантаження в типову папку, у вибрану папку або на зовнішній диск; постійні місця збереження для папок у хмарі; перевірка вільного місця перед завантаженням.
- Показує, які файли з хмари вже завантажено на цей Mac.
- Менеджер вивантажень із докачуванням; пункт «Upload to NaviDrive» у меню «Служби» Finder.
- Додавання файлів і папок за посиланням (посилання або ID Google Drive, спільне посилання Dropbox).
- Підрахунок розміру папок, створення папки, переміщення, переміщення в Кошик.
- Враховує денні ліміти передавання Google Drive і автоматично продовжує передавання після їх скидання.
- Статус у рядку меню, необов'язковий режим «не давати Mac засинати під час передавання», «Вийти після завершення», вихід утриманням ⌘Q.
- Оновлення в застосунку з GitHub Releases: перевірка щотижня або вручну; перед встановленням завантажений файл перевіряється (SHA-256, сертифікат підпису, версія).
- Інтерфейс англійською та російською.

## Вимоги

- macOS 15 або новіша.
- Apple silicon або Intel: релізні DMG, зібрані `Scripts/release.sh`, універсальні (`arm64` + `x86_64`); звичайна локальна збірка — лише `arm64`.
- Для збирання: Xcode 16 або новіший і [XcodeGen](https://github.com/yonaskolb/XcodeGen).

## Встановлення

Завантажте `NaviDrive-X.Y.Z.dmg` з [GitHub Releases](https://github.com/dotsentik/NaviDrive/releases), відкрийте його й перетягніть NaviDrive у «Програми». Перед першим відкриттям прочитайте розділ [Перший запуск](#перший-запуск).

## Перший запуск

Релізні збірки підписані власним сертифікатом проєкту й не нотаризовані Apple, тому на іншому Mac Gatekeeper блокує перший запуск із DMG.

1. Перетягніть NaviDrive у «Програми», потім клацніть правою кнопкою → «Відкрити» → «Відкрити».
2. Якщо це не допомогло, виконайте в Терміналі:
   `xattr -dr com.apple.quarantine /Applications/NaviDrive.app`
3. Якщо DMG надійшов через месенджер із пісочницею (наприклад, Telegram) і macOS повідомляє «File created by an AppSandbox», виконайте:
   `sudo xattr -cr /Applications/NaviDrive.app`

Щоб уникнути кроку 3, завантажуйте DMG з GitHub Releases у браузері або передавайте його через AirDrop.

Ці кроки потрібні лише один раз. Для оновлень, встановлених із самого застосунку (NaviDrive → Check for Updates…), вони не потрібні.

## Збирання з вихідного коду

```sh
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig   # then fill in the values, see below
xcodegen generate
xcodebuild -project NaviDrive.xcodeproj -scheme NaviDrive -configuration Release \
  -derivedDataPath ./DerivedData -quiet build
Scripts/make_dmg.sh   # ~/Desktop/NaviDrive-<version>.dmg
```

Релізи випускаються командою `Scripts/release.sh X.Y.Z` із чистої гілки `main`: скрипт збирає універсальний застосунок, звіряє сертифікат підпису з `Config/signing-fingerprint.txt`, створює `NaviDrive-X.Y.Z.dmg` і `NaviDrive-X.Y.Z.dmg.sha256`, бере примітки до релізу з `CHANGELOG.md` і публікує їх через `gh`. `Scripts/release.sh --dry-run X.Y.Z` збирає й перевіряє файли без публікації.

`NaviDrive.xcodeproj` генерується з `project.yml`; змінюйте налаштування збирання там, а не в проєкті Xcode.

Релізні збірки підписуються сертифікатом «NaviDrive Signing». Якщо його немає у вашій Зв'язці ключів, для локальної збірки змініть `CODE_SIGN_IDENTITY` у `project.yml`. Копії, підписані іншим сертифікатом, не можуть оновлювати копії, підписані оригінальним; докладніше — у [docs/SIGNING.md](docs/SIGNING.md).

## Налаштування OAuth

Облікові дані хмар у репозиторії не зберігаються. `Config/NaviDrive.xcconfig` підключає невідстежуваний `Config/Secrets.xcconfig`; його значення потрапляють до `Info.plist` як `$(GOOGLE_CLIENT_ID)`, `$(GOOGLE_CLIENT_SECRET)` і `$(DROPBOX_APP_KEY)`.

- **Google Drive**: створіть у Google Cloud Console OAuth-клієнт типу «Desktop app» з увімкненим Drive API і впишіть його Client ID та Client Secret у `Config/Secrets.xcconfig`. Без них у збірці немає вбудованого входу в Google, і користувачі вводять власні Client ID та Client Secret у налаштуваннях (вони зберігаються у Зв'язці ключів).
- **Dropbox**: створіть застосунок на dropbox.com/developers/apps, додайте redirect URI `http://127.0.0.1:53682/callback` і впишіть його App key у `DROPBOX_APP_KEY`. Без нього вхід у Dropbox недоступний.

## Безпека та конфіденційність

- OAuth-токени й облікові дані, введені користувачем, зберігаються у Зв'язці ключів macOS.
- Застосунок звертається лише до Google (accounts.google.com, oauth2.googleapis.com, www.googleapis.com) і Dropbox (dropbox.com, api.dropboxapi.com, content.dropboxapi.com), а під час перевірки оновлень — до GitHub (api.github.com і його серверів для завантаження релізів). Аналітики й телеметрії немає.
- Для входу використовується локальний loopback-сервер на 127.0.0.1, який приймає відповідь OAuth.
- Черга, історія та розміри папок зберігаються в локальній базі даних SQLite у `~/Library/Application Support/NaviDrive`.

## Структура репозиторію

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

## Ліцензія

MIT, див. файл [LICENSE](LICENSE).

<sub>Переклад зроблено за допомогою ШІ — виправлення вітаються в [issues](https://github.com/dotsentik/NaviDrive/issues).</sub>
