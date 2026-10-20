#!/bin/bash
# Сквозная проверка обновления NaviDrive без GitHub и без установленного приложения.
# Всё — в /tmp/navidrive-e2e: исходники (только файлы из git), две Debug-сборки 1.0.0 и 1.1.0 с тем же
# сертификатом и bundle id, DMG и .sha256, мок releases/latest на python3 -m http.server (127.0.0.1, случайный порт).
# Старая копия запускается в режиме «только обновление» (NAVIDRIVE_UPDATE_E2E=1, есть только в Debug):
# без базы данных, Связки ключей и аккаунтов. Реальные данные NaviDrive скрипт не читает и не пишет.
# Сценарии: успешное обновление и отказы (неверный SHA-256, ad-hoc подпись, версия в DMG не выше текущей,
# тег не выше текущего, версия в DMG не совпадает с тегом, хост ссылки не из списка разрешённых).
# В конце останавливается только запущенный скриптом сервер и удаляется только /tmp/navidrive-e2e
# (KEEP=1 — оставить для разбора).
# Запуск из любой папки: Scripts/test-update-e2e.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
E2E="/tmp/navidrive-e2e"
OLD_VERSION="1.0.0"
NEW_VERSION="1.1.0"
APPS="$E2E/Applications"
APP="$APPS/NaviDrive.app"
WWW="$E2E/www"
REPORT="$E2E/report.txt"
SERVER_PID=""
RESULTS=()
FAILED=0

fail() { echo "Ошибка: $*" >&2; exit 1; }
step() { echo "==> $*"; }

cleanup() {
    if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi
    if [ "${KEEP:-0}" != "1" ]; then rm -rf "$E2E"; else echo "Файлы оставлены в $E2E"; fi
}

[ -e "$E2E" ] && fail "$E2E уже существует — удалите папку от прошлого запуска"
mkdir -p "$E2E"
trap cleanup EXIT

step "Исходники (только файлы из git) → $E2E/src"
git -C "$ROOT" ls-files -z | rsync -a --from0 --files-from=- "$ROOT/" "$E2E/src/"
(cd "$E2E/src" && xcodegen generate --quiet)

# ENABLE_DEBUG_DYLIB=NO: отдельный NaviDrive.debug.dylib при hardened runtime не проходит library validation
# (у самоподписанного сертификата нет Team ID), поэтому Debug собирается одним бинарником.
build() {  # build <версия> <папка DerivedData>
    step "Debug-сборка $1"
    (cd "$E2E/src" && xcodebuild -project NaviDrive.xcodeproj -scheme NaviDrive -configuration Debug \
        -derivedDataPath "$2" -quiet MARKETING_VERSION="$1" ENABLE_DEBUG_DYLIB=NO build 2>&1 | grep -E 'error:' || true)
    [ -d "$2/Build/Products/Debug/NaviDrive.app" ] || fail "сборка $1 не удалась"
}
build "$OLD_VERSION" "$E2E/dd-old"
build "$NEW_VERSION" "$E2E/dd-new"
OLD_BUILD="$E2E/dd-old/Build/Products/Debug/NaviDrive.app"
NEW_BUILD="$E2E/dd-new/Build/Products/Debug/NaviDrive.app"
codesign --verify --deep --strict "$NEW_BUILD" || fail "сборка $NEW_VERSION не подписана"
[[ "$(codesign -dvv "$NEW_BUILD" 2>&1)" == *"Authority=NaviDrive Signing"* ]] \
    || fail "сборка подписана не сертификатом «NaviDrive Signing» — сквозную проверку подписи провести нельзя"

ADHOC_BUILD="$E2E/adhoc/NaviDrive.app"
mkdir -p "$E2E/adhoc"
ditto "$NEW_BUILD" "$ADHOC_BUILD"
codesign --force --deep --sign - "$ADHOC_BUILD" 2>/dev/null

step "Локальный сервер"
PORT="$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
mkdir -p "$WWW"
python3 -I -m http.server "$PORT" --bind 127.0.0.1 --directory "$WWW" >"$E2E/server.log" 2>&1 &
SERVER_PID=$!
BASE="http://127.0.0.1:$PORT"
for _ in $(seq 1 50); do curl -s -o /dev/null "$BASE/" && break; sleep 0.1; done

# scenario <имя> <тег> <.app в DMG> [sha|badsha] [хост ссылок]
scenario() {
    local name="$1" tag="$2" app="$3" sha="${4:-sha}" base="${5:-$BASE/$1}"
    local dir="$WWW/$name" dmg="NaviDrive-${tag#v}.dmg"
    mkdir -p "$dir" "$E2E/stage-$name"
    ditto "$app" "$E2E/stage-$name/NaviDrive.app"
    hdiutil create -quiet -srcfolder "$E2E/stage-$name" -volname NaviDrive -fs HFS+ -format UDZO -ov "$dir/$dmg" 2>/dev/null
    if [ "$sha" = "badsha" ]; then
        echo "$(printf '0%.0s' $(seq 1 64))  $dmg" > "$dir/$dmg.sha256"
    else
        (cd "$dir" && shasum -a 256 "$dmg" > "$dmg.sha256")
    fi
    local size; size=$(stat -f %z "$dir/$dmg")
    cat > "$dir/latest.json" <<EOF
{"tag_name": "$tag", "body": "E2E $name", "draft": false, "prerelease": false,
 "assets": [
  {"name": "$dmg", "size": $size, "browser_download_url": "$base/$dmg"},
  {"name": "$dmg.sha256", "size": 100, "browser_download_url": "$base/$dmg.sha256"}
 ]}
EOF
}

install_old() {
    rm -rf "$APPS" "$E2E/tmp" "$REPORT"
    mkdir -p "$APPS" "$E2E/tmp"
    ditto "$OLD_BUILD" "$APP"
}

run_old() {  # run_old <путь фида> → код выхода старой копии
    local code=0
    env TMPDIR="$E2E/tmp/" NAVIDRIVE_UPDATE_E2E=1 NAVIDRIVE_UPDATE_FEED="$BASE/$1" NAVIDRIVE_UPDATE_E2E_REPORT="$REPORT" \
        "$APP/Contents/MacOS/NaviDrive" -AppleLanguages '(en)' </dev/null >/dev/null 2>&1 || code=$?
    return $code
}

version_of() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null || echo "?"; }

record() {  # record <сценарий> <ok|fail> <подробности>
    if [ "$2" = ok ]; then RESULTS+=("прошёл      $1"); else RESULTS+=("НЕ ПРОШЁЛ   $1 — $3"); FAILED=1; fi
    echo "    $1: $2${3:+ ($3)}"
}

step "Сценарии"
scenario ok v$NEW_VERSION "$NEW_BUILD"
scenario bad-sha v$NEW_VERSION "$NEW_BUILD" badsha
scenario adhoc v$NEW_VERSION "$ADHOC_BUILD"
scenario dmg-not-newer v$NEW_VERSION "$OLD_BUILD"
scenario tag-not-newer v$OLD_VERSION "$OLD_BUILD"
scenario tag-mismatch v1.2.0 "$NEW_BUILD"
scenario bad-host v$NEW_VERSION "$NEW_BUILD" sha "https://evil.example.com/download"

# 1. Успешное обновление.
install_old
if run_old ok/latest.json && grep -q "^installing $NEW_VERSION" "$REPORT"; then
    HELPER_LOG="$E2E/tmp/com.navidrive.NaviDrive.update/replace.log"
    for _ in $(seq 1 120); do
        grep -qE 'new version launched|failed|cancelled|could not' "$HELPER_LOG" 2>/dev/null && break
        sleep 0.5
    done
    problems=()
    [ "$(version_of "$APP")" = "$NEW_VERSION" ] || problems+=("версия $(version_of "$APP")")
    grep -q "^start $NEW_VERSION " "$REPORT" || problems+=("новая копия не запускалась")
    grep -q 'new version launched' "$HELPER_LOG" 2>/dev/null || problems+=("нет записи о запуске в журнале")
    [ ! -e "$APP.old" ] || problems+=("NaviDrive.app.old не удалён")
    ! xattr -p com.apple.quarantine "$APP" >/dev/null 2>&1 || problems+=("есть com.apple.quarantine")
    codesign --verify --deep --strict "$APP" 2>/dev/null || problems+=("подпись невалидна")
    if [ ${#problems[@]} -eq 0 ]; then
        record "успешное обновление $OLD_VERSION → $NEW_VERSION (версия, перезапуск, .old, quarantine, подпись)" ok
    else
        record "успешное обновление" fail "${problems[*]}"
    fi
else
    record "успешное обновление" fail "$(tail -1 "$REPORT" 2>/dev/null)"
fi

# 2. Отказы: старая копия должна остаться на месте, целой и запускаемой.
reject() {  # reject <сценарий> <ожидаемая строка в отчёте> <описание>
    install_old
    run_old "$1/latest.json" || true
    local problems=()
    grep -q "$2" "$REPORT" || problems+=("в отчёте нет «$2»: $(tail -1 "$REPORT" 2>/dev/null)")
    grep -q '^installing' "$REPORT" && problems+=("установка была запущена")
    sleep 1
    [ "$(version_of "$APP")" = "$OLD_VERSION" ] || problems+=("версия стала $(version_of "$APP")")
    [ ! -e "$APP.old" ] || problems+=("появился NaviDrive.app.old")
    compgen -G "$APPS/.NaviDrive.app.update-*" >/dev/null && problems+=("остался .NaviDrive.app.update-*")
    codesign --verify --deep --strict "$APP" 2>/dev/null || problems+=("подпись старой копии невалидна")
    rm -f "$REPORT"
    run_old missing/latest.json && grep -q '^uptodate' "$REPORT" || problems+=("старая копия не запускается")
    if [ ${#problems[@]} -eq 0 ]; then record "$3" ok; else record "$3" fail "${problems[*]}"; fi
}
reject bad-sha       'checksumMismatch'  "неверный SHA-256"
reject adhoc         'signatureInvalid'  "новая версия подписана ad-hoc"
reject dmg-not-newer 'versionMismatch'   "версия в DMG не выше текущей"
reject tag-not-newer '^uptodate'         "тег не выше текущей версии"
reject tag-mismatch  'versionMismatch'   "версия в DMG не совпадает с тегом"
reject bad-host      'insecureURL'       "хост ссылки не из списка разрешённых"

echo
echo "Итог:"
printf '  %s\n' "${RESULTS[@]}"
exit $FAILED
