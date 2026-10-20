# Правила сборки и экономии контекста
1. НИКОГДА не запускай `xcodebuild` без флага `-quiet`. Стандартный вывод xcodebuild переполняет контекстное окно.
2. Для проверки компиляции ВСЕГДА используй команду:
   `xcodebuild -project NaviDrive.xcodeproj -scheme NaviDrive -configuration Release -derivedDataPath ./DerivedData -quiet build 2>&1 | xcbeautify`
3. Не редактируй файл `project.pbxproj` вручную. Все изменения настроек проекта, таргетов и `Info.plist` вноси в `project.yml` и перегенерируй проект командой `xcodegen generate`.
4. Пиши чистый нативный код на Swift 6 без сторонних SPM-зависимостей (используй только системные фреймворки macOS: SwiftUI, AppKit, Foundation, Network, Security, SQLite3, CryptoKit).
5. Все новые строки интерфейса добавляй в Localizable.xcstrings сразу на двух языках: английском (основной) и русском. Не хардкодь текст в коде.
