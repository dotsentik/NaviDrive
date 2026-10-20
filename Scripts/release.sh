#!/bin/bash
# Выпуск NaviDrive: Release-сборка (universal arm64 + x86_64, minos 15.0), DMG через make_dmg.sh,
# NaviDrive-X.Y.Z.dmg.sha256 («<hash>  <имя файла>»), публикация в GitHub Releases через gh.
# Публикация — только из ветки main с чистой рабочей копией, после подтверждения y/N.
# В других ветках скрипт собирает DMG и .sha256 и пропускает публикацию.
# В релиз попадают только DMG и .sha256. Заметки — раздел «## [X.Y.Z]» из CHANGELOG.md.
# Запуск из любой папки: Scripts/release.sh 1.2.0
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP="$ROOT/DerivedData/Build/Products/Release/NaviDrive.app"
MIN_MACOS="15.0"

fail() { echo "Ошибка: $*" >&2; exit 1; }
step() { echo "==> $*"; }

VERSION="${1:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "укажите версию X.Y.Z, например: Scripts/release.sh 1.2.0"
TAG="v$VERSION"
DMG_NAME="NaviDrive-$VERSION.dmg"
OUT="$ROOT/build/release/$VERSION"

cd "$ROOT"

WORK="$(mktemp -d -t navidrive-release)"
trap 'rm -rf "$WORK"' EXIT

# Ветка и состояние рабочей копии — до сборки (сборка может перегенерировать проект).
BRANCH="$(git branch --show-current)"
PUBLISH=1
SKIP_REASON=""
if [ "$BRANCH" != "main" ]; then
    PUBLISH=0
    SKIP_REASON="текущая ветка «$BRANCH», публиковать можно только из main"
elif [ -n "$(git status --porcelain)" ]; then
    PUBLISH=0
    SKIP_REASON="в рабочей копии есть незакоммиченные изменения"
fi

step "Заметки релиза из CHANGELOG.md"
NOTES="$WORK/notes.md"
[ -f CHANGELOG.md ] || fail "нет CHANGELOG.md"
awk -v version="$VERSION" '
    /^## / {
        heading = substr($0, 4)
        gsub(/[][]/, "", heading)
        split(heading, parts, " ")
        if (found) exit
        if (parts[1] == version) { found = 1; next }
    }
    found { print }
' CHANGELOG.md | sed -e '/./,$!d' > "$NOTES"
[ -s "$NOTES" ] || fail "в CHANGELOG.md нет раздела «## [$VERSION]» или он пуст"

step "Сборка Release (universal, macOS $MIN_MACOS+)"
if command -v xcodegen >/dev/null; then xcodegen generate --quiet; fi
xcodebuild -project NaviDrive.xcodeproj -scheme NaviDrive -configuration Release -derivedDataPath ./DerivedData \
    -quiet ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS" clean build \
    || fail "сборка не удалась"

step "Проверка сборки"
BINARY="$APP/Contents/MacOS/NaviDrive"
ARCHS_FOUND="$(lipo -archs "$BINARY")"
for arch in arm64 x86_64; do
    [[ " $ARCHS_FOUND " == *" $arch "* ]] || fail "в $BINARY нет архитектуры $arch (есть: $ARCHS_FOUND)"
    MINOS="$(vtool -arch "$arch" -show-build "$BINARY" | awk '/minos/ {print $2; exit}')"
    [ "$MINOS" = "$MIN_MACOS" ] || fail "minos для $arch — $MINOS, ожидается $MIN_MACOS"
done
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[ "$PLIST_VERSION" = "$VERSION" ] \
    || fail "версия в Info.plist ($PLIST_VERSION) не совпадает с тегом $TAG — поправьте MARKETING_VERSION в project.yml"
REPO="$(/usr/libexec/PlistBuddy -c 'Print :NDGitHubRepo' "$APP/Contents/Info.plist" 2>/dev/null || true)"
[ -n "$REPO" ] || fail "в Info.plist нет NDGitHubRepo"
codesign --verify --deep --strict "$APP" || fail "подпись $APP не прошла проверку"

step "DMG"
"$SCRIPT_DIR/make_dmg.sh"
mkdir -p "$OUT"
rm -f "$OUT/$DMG_NAME" "$OUT/$DMG_NAME.sha256"
mv "$HOME/Desktop/$DMG_NAME" "$OUT/$DMG_NAME"
(cd "$OUT" && shasum -a 256 "$DMG_NAME" > "$DMG_NAME.sha256")
echo "Готово: $OUT/$DMG_NAME"
echo "        $OUT/$DMG_NAME.sha256"

if [ "$PUBLISH" -eq 1 ] && [ -n "$(git status --porcelain)" ]; then
    PUBLISH=0
    SKIP_REASON="после сборки рабочая копия изменилась: $(git status --porcelain | head -3 | tr '\n' ' ')"
fi
if [ "$PUBLISH" -eq 0 ]; then
    echo "Публикация пропущена: $SKIP_REASON."
    exit 0
fi

step "Публикация $TAG в $REPO"
command -v gh >/dev/null || fail "не найден gh (brew install gh)"
gh auth status >/dev/null 2>&1 || fail "gh не авторизован: gh auth login"
git fetch --quiet origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] \
    || fail "локальная main не совпадает с origin/main — сначала git push / git pull"
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    fail "релиз $TAG уже существует"
fi

echo
echo "Релиз:   $TAG ($REPO, коммит $(git rev-parse --short HEAD))"
echo "Файлы:   $DMG_NAME, $DMG_NAME.sha256"
echo "Заметки:"
sed 's/^/  /' "$NOTES"
echo
read -r -p "Опубликовать? [y/N] " answer
if [[ ! "$answer" =~ ^[yY]$ ]]; then
    echo "Публикация отменена."
    exit 0
fi

gh release create "$TAG" "$OUT/$DMG_NAME" "$OUT/$DMG_NAME.sha256" \
    --repo "$REPO" --target "$(git rev-parse HEAD)" --title "NaviDrive $VERSION" --notes-file "$NOTES"
echo "Опубликовано: $TAG"
