#!/bin/bash
# Собирает установочный DMG NaviDrive: приложение слева, ярлык Applications справа, фон со стрелкой.
# Только встроенные инструменты macOS: hdiutil, ditto, osascript, sips, tiffutil, PlistBuddy, swift.
# Запуск из любой папки: scripts/make_dmg.sh
# Результат: ~/Desktop/NaviDrive-<версия>.dmg (существующий файл с тем же именем перезаписывается).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP="$ROOT/DerivedData/Build/Products/Release/NaviDrive.app"
VOLUME_NAME="NaviDrive"
BACKGROUND="$SCRIPT_DIR/dmg-background.png"
BACKGROUND_2X="$SCRIPT_DIR/dmg-background@2x.png"
BACKGROUND_SOURCE="$SCRIPT_DIR/make_dmg_background.swift"
# Окно 600×400 и центры иконок — те же, что в make_dmg_background.swift.
WINDOW_W=600
WINDOW_H=400
APP_POS="150, 190"
APPLICATIONS_POS="450, 190"

fail() { echo "Ошибка: $*" >&2; exit 1; }
step() { echo "==> $*"; }

[ -d "$APP" ] || fail "не найдено $APP
Сначала соберите Release:
  cd \"$ROOT\" && xcodebuild -project NaviDrive.xcodeproj -scheme NaviDrive -configuration Release -derivedDataPath ./DerivedData -quiet build"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null)" \
    || fail "в $APP/Contents/Info.plist нет CFBundleShortVersionString"
DMG="$HOME/Desktop/NaviDrive-$VERSION.dmg"

if [ -d "/Volumes/$VOLUME_NAME" ]; then
    fail "уже подключён том /Volumes/$VOLUME_NAME (например, старый DMG). Извлеките его в Finder и запустите скрипт снова."
fi

WORK="$(mktemp -d -t navidrive-dmg)"
DEVICE=""
cleanup() {
    if [ -n "$DEVICE" ]; then hdiutil detach "$DEVICE" -quiet -force >/dev/null 2>&1 || true; fi
    rm -rf "$WORK"
}
trap cleanup EXIT

# Фон: рисуется кодом, если PNG ещё нет или скрипт рисования новее.
if [ ! -f "$BACKGROUND" ] || [ ! -f "$BACKGROUND_2X" ] || [ "$BACKGROUND_SOURCE" -nt "$BACKGROUND" ]; then
    step "Рисую фон окна"
    swift "$BACKGROUND_SOURCE" "$SCRIPT_DIR"
fi
[ "$(sips -g pixelWidth "$BACKGROUND" | awk '/pixelWidth/ {print $2}')" = "$WINDOW_W" ] \
    || fail "ширина $BACKGROUND должна быть $WINDOW_W px"
[ "$(sips -g pixelWidth "$BACKGROUND_2X" | awk '/pixelWidth/ {print $2}')" = "$((WINDOW_W * 2))" ] \
    || fail "ширина $BACKGROUND_2X должна быть $((WINDOW_W * 2)) px"

step "Готовлю содержимое образа (версия $VERSION)"
STAGING="$WORK/staging"
mkdir -p "$STAGING/.background"
ditto "$APP" "$STAGING/NaviDrive.app"
ln -s /Applications "$STAGING/Applications"
# Один TIFF с 1x и @2x: Finder сам выбирает нужное разрешение на Retina.
tiffutil -cathidpicheck "$BACKGROUND" "$BACKGROUND_2X" -out "$STAGING/.background/background.tiff" >/dev/null 2>&1
ICON_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP/Contents/Info.plist" 2>/dev/null || echo AppIcon)"
ICON="$APP/Contents/Resources/${ICON_NAME%.icns}.icns"
[ -f "$ICON" ] || fail "не найдена иконка приложения $ICON"

step "Создаю временный образ"
SIZE_MB=$(( $(du -sm "$STAGING" | awk '{print $1}') + 20 ))
RW_DMG="$WORK/rw.dmg"
hdiutil create -quiet -srcfolder "$STAGING" -volname "$VOLUME_NAME" -fs HFS+ \
    -format UDRW -size "${SIZE_MB}m" "$RW_DMG"

ATTACH="$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG")"
DEVICE="$(echo "$ATTACH" | awk 'NR==1 {print $1}')"
MOUNT="$(echo "$ATTACH" | awk -F'\t' '/\/Volumes\// {print $NF}' | sed 's/[[:space:]]*$//')"
[ -d "$MOUNT" ] || fail "не удалось подключить временный образ"

step "Настраиваю окно Finder"
configure_finder_window() {
osascript <<EOF
tell application "Finder"
    tell disk "$VOLUME_NAME"
        open
        delay 2
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set pathbar visible of container window to false
        -- bounds — рамка окна; заголовок окна ~28 pt сверху.
        set the bounds of container window to {200, 120, 200 + $WINDOW_W, 120 + $WINDOW_H + 28}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:background.tiff"
        set position of item "NaviDrive.app" of container window to {$APP_POS}
        set position of item "Applications" of container window to {$APPLICATIONS_POS}
        update without registering applications
        delay 2
        close
    end tell
end tell
EOF
}
# Второй проход обязателен: после первого Finder сохраняет расстановку иконок,
# но размер иконок и фон — не всегда.
configure_finder_window
sleep 2
configure_finder_window

# Finder записывает .DS_Store не сразу (окончательно — при отключении тома) — ждём появления файла до 15 с.
for _ in $(seq 1 30); do
    [ -f "$MOUNT/.DS_Store" ] && break
    sleep 0.5
done
[ -f "$MOUNT/.DS_Store" ] || echo "Предупреждение: Finder не сохранил раскладку окна (.DS_Store)" >&2

# Иконка тома — иконка приложения. Копируется только после настройки окна: и hdiutil -srcfolder,
# и Finder при настройке окна удаляют .VolumeIcon.icns.
cp "$ICON" "$MOUNT/.VolumeIcon.icns"
# Флаг «своя иконка» (kHasCustomIcon, 0x0400 в Finder flags) на корне тома — тоже после настройки окна:
# Finder сохраняет параметры окна в FinderInfo корня и сбросил бы флаг. Остальные байты сохраняются.
FINDER_INFO="$(xattr -px com.apple.FinderInfo "$MOUNT" 2>/dev/null | tr -d ' \n' || true)"
[ ${#FINDER_INFO} -eq 64 ] || FINDER_INFO="$(printf '0%.0s' $(seq 1 64))"
FLAGS_BYTE=$(( 0x${FINDER_INFO:16:2} | 0x04 ))
FINDER_INFO="${FINDER_INFO:0:16}$(printf '%02x' "$FLAGS_BYTE")${FINDER_INFO:18}"
xattr -wx com.apple.FinderInfo "$FINDER_INFO" "$MOUNT"

rm -rf "$MOUNT/.fseventsd"
chmod -Rf go-w "$MOUNT" || true
sync
hdiutil detach "$DEVICE" -quiet || { sleep 2; hdiutil detach "$DEVICE" -quiet -force; }
DEVICE=""

step "Сжимаю образ (UDZO)"
hdiutil convert -quiet "$RW_DMG" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG"

step "Проверяю образ"
hdiutil verify -quiet "$DMG" || fail "hdiutil verify: образ повреждён"

echo
echo "Готово: $DMG"
echo "Размер: $(du -h "$DMG" | awk '{print $1}')"
