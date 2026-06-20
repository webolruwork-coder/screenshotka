#!/bin/bash
# Собирает красивый установочный .dmg: иконка приложения → стрелка → папка Applications
# (как у Shottr/типовых macOS-приложений). Требует create-dmg (brew install create-dmg).
set -e
cd "$(dirname "$0")"
source ./sparkle.config

APP="build/Скриншотилка.app"
APP_BASENAME="Скриншотилка.app"
# Имя ФАЙЛА — латиницей: GitHub вырезает не-ASCII из имён ассетов релиза.
# Название ТОМА (--volname) и само приложение внутри остаются «Скриншотилка».
OUT="dist/Screenshotka-$APP_VERSION.dmg"

[ -d "$APP" ] || { echo "✗ Нет $APP — сначала ./build.sh"; exit 1; }
command -v create-dmg >/dev/null || { echo "✗ Нет create-dmg. Установи: brew install create-dmg"; exit 1; }

mkdir -p dist
rm -f "$OUT"

# Стейджинг: в исходной папке только приложение (Applications-ссылку добавит create-dmg).
STAGE="$(mktemp -d)/src"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"

echo "→ Сборка DMG: $OUT"
create-dmg \
  --volname "Скриншотилка" \
  --background "Resources/dmg-background.png" \
  --window-pos 200 120 \
  --window-size 660 420 \
  --icon-size 128 \
  --icon "$APP_BASENAME" 170 210 \
  --hide-extension "$APP_BASENAME" \
  --app-drop-link 490 210 \
  --no-internet-enable \
  "$OUT" \
  "$STAGE" || true   # create-dmg возвращает ненулевой код, если не смог подписать — DMG всё равно создаётся

rm -rf "$(dirname "$STAGE")"
[ -f "$OUT" ] && echo "✓ Готово: $OUT ($(du -h "$OUT" | cut -f1))" || { echo "✗ DMG не создан"; exit 1; }
