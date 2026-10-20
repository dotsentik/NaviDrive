# NaviDrive

<p align="center"><img src="docs/screenshots/navidrive-hero.png" alt="NaviDrive: клиент Google Drive и Dropbox для macOS" width="880"></p>

<p align="center">Нативный клиент Google Drive и Dropbox для macOS: быстрое скачивание и отправка больших файлов и папок с докачкой.</p>

Нативный клиент Google Drive и Dropbox для macOS: быстрое скачивание и отправка больших файлов и папок с докачкой.

Подробная документация — в [README.md](README.md) (на английском).

## Возможности

- Просмотр Google Drive (Мой диск, Доступные мне) и Dropbox, несколько облаков одновременно.
- Менеджер загрузок: параллельное скачивание частями, пауза и продолжение, прогресс сохраняется после перезапуска, обрыва сети и отключения диска.
- Проверка контрольной суммы после скачивания.
- Скачивание в папку по умолчанию, в свою папку или на внешний диск.
- Отметка файлов, уже скачанных на этот Mac.
- Отправка файлов с докачкой, пункт «Upload to NaviDrive» в меню Службы Finder.
- Добавление файлов и папок по ссылке, подсчёт размера папок, перемещение, корзина.
- Учёт дневных лимитов Google Drive.
- Обновления из GitHub Releases с проверкой SHA-256, сертификата подписи и версии.

## Требования

macOS 15 или новее; релизные DMG универсальные (Apple silicon и Intel).

## Установка

Скачайте `NaviDrive-X.Y.Z.dmg` из [GitHub Releases](https://github.com/dotsentik/NaviDrive/releases), откройте и перетащите NaviDrive в «Программы».

## Первый запуск

Сборка подписана собственным сертификатом и не нотаризована Apple, поэтому на другом Mac Gatekeeper блокирует первый запуск из DMG.

1. Перетащите NaviDrive в «Программы», затем правый клик → «Открыть» → «Открыть».
2. Если не помогло, выполните в Терминале:
   `xattr -dr com.apple.quarantine /Applications/NaviDrive.app`
3. Если DMG пришёл через мессенджер с песочницей (например, Telegram) и macOS пишет «File created by an AppSandbox», выполните:
   `sudo xattr -cr /Applications/NaviDrive.app`

Чтобы шаг 3 не понадобился, скачивайте DMG из GitHub Releases в браузере или передавайте по AirDrop.

Эти шаги нужны только один раз: обновления внутри приложения ставятся без них.

## Сборка

```sh
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig   # впишите свои значения
xcodegen generate
xcodebuild -project NaviDrive.xcodeproj -scheme NaviDrive -configuration Release \
  -derivedDataPath ./DerivedData -quiet build
Scripts/make_dmg.sh
```

Настройка OAuth и подписи — в [README.md](README.md) и [docs/SIGNING.md](docs/SIGNING.md).

## Безопасность

Токены хранятся в Связке ключей macOS. Приложение обращается только к Google, Dropbox и GitHub (проверка обновлений), аналитики и телеметрии нет.

## Лицензия

MIT, см. файл [LICENSE](LICENSE).
