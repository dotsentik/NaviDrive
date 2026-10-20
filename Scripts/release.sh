#!/bin/bash
# Выпуск NaviDrive: Release-сборка (universal arm64 + x86_64, minos 15.0), DMG через make_dmg.sh,
# NaviDrive-X.Y.Z.dmg.sha256 («<hash>  <имя файла>»), публикация в GitHub Releases через gh.
# Публикация — только из ветки main с чистой рабочей копией, после подтверждения y/N.
# В других ветках скрипт собирает DMG и .sha256 и пропускает публикацию.
# В релиз попадают только DMG и .sha256. Заметки — раздел «## [X.Y.Z]» из CHANGELOG.md.
# Подпись: отпечаток листового сертификата собранного .app должен совпасть с Config/signing-fingerprint.txt
# (см. docs/SIGNING.md); иначе выпуск отменяется. Печатается срок действия сертификата.
# Запуск из любой папки: Scripts/release.sh [--dry-run] 1.2.0
#   --dry-run — собрать и проверить DMG и .sha256, ничего не публикуя.
# NAVIDRIVE_DERIVED_DATA и NAVIDRIVE_RELEASE_OUT переопределяют папку сборки и папку результата.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DERIVED_DATA="${NAVIDRIVE_DERIVED_DATA:-$ROOT/DerivedData}"
APP="$DERIVED_DATA/Build/Products/Release/NaviDrive.app"
MIN_MACOS="15.0"
FINGERPRINT_FILE="$ROOT/Config/signing-fingerprint.txt"
NOTES_FOOTER="$SCRIPT_DIR/release-notes-footer.md"
EXPIRY_WARNING_DAYS=180

fail() { echo "Ошибка: $*" >&2; exit 1; }
step() { echo "==> $*"; }

DRY_RUN=0
VERSION=""
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        -*) fail "неизвестный параметр $arg" ;;
        *) [ -z "$VERSION" ] || fail "версия указана дважды"; VERSION="$arg" ;;
    esac
done
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "укажите версию X.Y.Z, например: Scripts/release.sh 1.2.0"
TAG="v$VERSION"
DMG_NAME="NaviDrive-$VERSION.dmg"
OUT="${NAVIDRIVE_RELEASE_OUT:-$ROOT/build/release/$VERSION}"

# Отпечаток в виде 64 шестнадцатеричных символов в верхнем регистре: без «:», пробелов и комментариев.
normalize_fingerprint() { tr -d ': \t' | tr '[:lower:]' '[:upper:]'; }
[ -f "$FINGERPRINT_FILE" ] || fail "нет $FINGERPRINT_FILE"
EXPECTED_FINGERPRINT="$(grep -v '^[[:space:]]*#' "$FINGERPRINT_FILE" | normalize_fingerprint | tr -d '\n')"
[[ "$EXPECTED_FINGERPRINT" =~ ^[0-9A-F]{64}$ ]] || fail "в $FINGERPRINT_FILE нет SHA-256 отпечатка"

cd "$ROOT"

WORK="$(mktemp -d -t navidrive-release)"
trap 'rm -rf "$WORK"' EXIT

# Ветка и состояние рабочей копии — до сборки (сборка может перегенерировать проект).
BRANCH="$(git branch --show-current)"
PUBLISH=1
SKIP_REASON=""
if [ "$DRY_RUN" -eq 1 ]; then
    PUBLISH=0
    SKIP_REASON="режим --dry-run"
elif [ "$BRANCH" != "main" ]; then
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
# Как открыть сборку без нотаризации на другом Mac — в конце заметок каждого релиза.
[ -f "$NOTES_FOOTER" ] && cat "$NOTES_FOOTER" >> "$NOTES"

step "Сборка Release (universal, macOS $MIN_MACOS+)"
if command -v xcodegen >/dev/null; then xcodegen generate --quiet; fi
xcodebuild -project NaviDrive.xcodeproj -scheme NaviDrive -configuration Release -derivedDataPath "$DERIVED_DATA" \
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

step "Сертификат подписи"
CERTS="$WORK/certs"
mkdir -p "$CERTS"
(cd "$CERTS" && codesign -d --extract-certificates=cert "$APP" 2>/dev/null) || true
[ -f "$CERTS/cert0" ] || fail "у $APP нет сертификата подписи (ad-hoc?) — нужна подпись «NaviDrive Signing»"
ACTUAL_FINGERPRINT="$(openssl x509 -inform DER -in "$CERTS/cert0" -noout -fingerprint -sha256 | cut -d= -f2 | normalize_fingerprint)"
if [ "$ACTUAL_FINGERPRINT" != "$EXPECTED_FINGERPRINT" ]; then
    fail "приложение подписано другим сертификатом:
  в подписи:                       $ACTUAL_FINGERPRINT
  в Config/signing-fingerprint.txt: $EXPECTED_FINGERPRINT
Установленные копии отклонят такое обновление. См. docs/SIGNING.md."
fi
echo "Отпечаток SHA-256 совпадает: $ACTUAL_FINGERPRINT"
NOT_AFTER="$(openssl x509 -inform DER -in "$CERTS/cert0" -noout -enddate | cut -d= -f2)"
EXPIRY_EPOCH="$(LC_ALL=C date -j -f '%b %e %T %Y %Z' "$NOT_AFTER" '+%s' 2>/dev/null || echo 0)"
if [ "$EXPIRY_EPOCH" -gt 0 ]; then
    DAYS_LEFT=$(( (EXPIRY_EPOCH - $(date '+%s')) / 86400 ))
    echo "Сертификат действует до $(date -r "$EXPIRY_EPOCH" '+%Y-%m-%d') (осталось дней: $DAYS_LEFT)"
    [ "$DAYS_LEFT" -ge 0 ] || fail "срок действия сертификата истёк — см. docs/SIGNING.md"
    if [ "$DAYS_LEFT" -lt "$EXPIRY_WARNING_DAYS" ]; then
        echo "Предупреждение: до окончания срока сертификата меньше $EXPIRY_WARNING_DAYS дней — пора выпускать переходную версию (docs/SIGNING.md)." >&2
    fi
else
    echo "Предупреждение: не удалось разобрать дату окончания сертификата «$NOT_AFTER»" >&2
fi

step "DMG"
mkdir -p "$OUT"
rm -f "$OUT/$DMG_NAME" "$OUT/$DMG_NAME.sha256"
NAVIDRIVE_APP="$APP" NAVIDRIVE_DMG_DIR="$OUT" "$SCRIPT_DIR/make_dmg.sh"
[ -f "$OUT/$DMG_NAME" ] || fail "make_dmg.sh не создал $OUT/$DMG_NAME"
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
