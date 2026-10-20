
---

**First launch.** NaviDrive is signed with its own certificate and is not notarized by Apple. On a new Mac: drag it to Applications, then right-click → Open → Open. If macOS still refuses, run `xattr -dr com.apple.quarantine /Applications/NaviDrive.app`; if the DMG came through a sandboxed messenger (e.g. Telegram) and macOS says "File created by an AppSandbox", run `sudo xattr -cr /Applications/NaviDrive.app`. Prefer downloading the DMG here in a browser or sending it over AirDrop.

**Первый запуск.** NaviDrive подписан собственным сертификатом и не нотаризован Apple. На новом Mac перетащите его в «Программы», затем правый клик → «Открыть» → «Открыть». Если macOS всё равно не открывает, выполните `xattr -dr com.apple.quarantine /Applications/NaviDrive.app`; если DMG пришёл через мессенджер с песочницей (например, Telegram) и macOS пишет «File created by an AppSandbox» — `sudo xattr -cr /Applications/NaviDrive.app`. Лучше скачивать DMG отсюда в браузере или передавать по AirDrop.
