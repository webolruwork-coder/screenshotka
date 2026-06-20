#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
#  Выпуск нового релиза с авто-обновлением через Sparkle.
#
#  Использование:
#     ./release.sh             — выпустить ту же видимую версию, +1 к номеру сборки
#     ./release.sh 1.1         — выпустить версию 1.1 (номер сборки тоже +1)
#
#  Что делает:
#    1) бампит номер сборки (CFBundleVersion) в sparkle.config;
#    2) собирает .app (build.sh);
#    3) пакует в zip (ditto, с сохранением симлинков фреймворка);
#    4) генерирует/подписывает appcast.xml (EdDSA-подпись из Keychain);
#    5) печатает готовую команду публикации на GitHub Releases.
# ─────────────────────────────────────────────────────────────────────────────
set -e
cd "$(dirname "$0")"
source ./sparkle.config

GEN="Vendor/Sparkle/bin/generate_appcast"
DIST="dist"

# 1. Версия и номер сборки
NEW_VERSION="${1:-$APP_VERSION}"
NEW_BUILD=$((APP_BUILD + 1))
echo "→ Релиз: версия $NEW_VERSION, сборка $NEW_BUILD"

# Записываем обратно в sparkle.config (build.sh подхватит)
/usr/bin/sed -i '' -E "s/^APP_VERSION=.*/APP_VERSION=\"$NEW_VERSION\"/" sparkle.config
/usr/bin/sed -i '' -E "s/^APP_BUILD=.*/APP_BUILD=\"$NEW_BUILD\"/" sparkle.config

if [ "$SPARKLE_GITHUB_OWNER" = "CHANGE_ME" ]; then
    echo "⚠️  В sparkle.config не задан SPARKLE_GITHUB_OWNER — appcast соберётся, но"
    echo "    ссылки на скачивание будут с заглушкой 'CHANGE_ME'. Поправь и перезапусти."
fi

# 2. Сборка
echo "→ Сборка приложения…"
./build.sh >/dev/null
echo "  ✓ собрано"

# 3. Архив (ditto сохраняет симлинки внутри Sparkle.framework — обычный zip их ломает)
rm -rf "$DIST"; mkdir -p "$DIST"
ZIP="$DIST/Screenshotka-$NEW_VERSION.zip"
ditto -c -k --keepParent "build/Скриншотилка.app" "$ZIP"
echo "→ Архив: $ZIP ($(du -h "$ZIP" | cut -f1))"

# 4. appcast.xml с EdDSA-подписью. Ссылки на скачивание указывают на ассеты
#    GitHub-релиза с тегом v$NEW_VERSION.
TAG="v$NEW_VERSION"
PREFIX="https://github.com/$SPARKLE_GITHUB_OWNER/$SPARKLE_GITHUB_REPO/releases/download/$TAG/"
echo "→ Генерация appcast.xml…"
"$GEN" "$DIST" --download-url-prefix "$PREFIX"
echo "  ✓ $DIST/appcast.xml"

# 5. Инструкция по публикации
echo ""
echo "──────────────────────────────────────────────────────────────────────"
echo "  Готово к публикации. Создай релиз на GitHub и приложи ОБА файла:"
echo ""
echo "    • $ZIP"
echo "    • $DIST/appcast.xml"
echo ""
echo "  Через gh CLI (одной командой):"
echo ""
echo "    gh release create $TAG \\"
echo "      \"$ZIP\" \\"
echo "      \"$DIST/appcast.xml\" \\"
echo "      --repo $SPARKLE_GITHUB_OWNER/$SPARKLE_GITHUB_REPO \\"
echo "      --title \"$NEW_VERSION\" --notes \"Обновление $NEW_VERSION\""
echo ""
echo "  Друзья с уже установленным приложением получат это обновление"
echo "  автоматически (проверка раз в сутки) или через меню → «Проверить обновления…»."
echo "──────────────────────────────────────────────────────────────────────"
