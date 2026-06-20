#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
#  Публикация на GitHub Releases «под ключ».
#
#  Предусловие (один раз):  gh auth login
#
#  Использование:
#     ./publish-github.sh            — опубликовать ТЕКУЩУЮ версию (фид заработает,
#                                      кнопка «Проверить обновления» перестанет
#                                      ошибаться и скажет «актуальная версия»)
#     ./publish-github.sh 1.1        — выпустить НОВУЮ версию 1.1 (бамп сборки +
#                                      друзья получат обновление)
#
#  Делает: подставляет твой GitHub-логин в sparkle.config (если там CHANGE_ME),
#  создаёт репозиторий (если нет), собирает, пакует, подписывает appcast,
#  создаёт релиз с ассетами и проверяет, что фид отдаёт 200.
# ─────────────────────────────────────────────────────────────────────────────
set -e
cd "$(dirname "$0")"

command -v gh >/dev/null || { echo "✗ Нет gh CLI. Установи: brew install gh"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "✗ Сначала авторизуйся: gh auth login"; exit 1; }

source ./sparkle.config

# 1. Автоподстановка GitHub-логина из авторизованной учётки
ME="$(gh api user --jq .login)"
if [ "$SPARKLE_GITHUB_OWNER" = "CHANGE_ME" ]; then
    echo "→ Подставляю владельца: $ME"
    /usr/bin/sed -i '' -E "s/^SPARKLE_GITHUB_OWNER=.*/SPARKLE_GITHUB_OWNER=\"$ME\"/" sparkle.config
    source ./sparkle.config
fi
REPO="$SPARKLE_GITHUB_OWNER/$SPARKLE_GITHUB_REPO"

# 2. Версия: с аргументом — бампим (новый апдейт), без — публикуем текущую как есть
if [ -n "$1" ]; then
    NEW_VERSION="$1"; NEW_BUILD=$((APP_BUILD + 1))
    /usr/bin/sed -i '' -E "s/^APP_VERSION=.*/APP_VERSION=\"$NEW_VERSION\"/" sparkle.config
    /usr/bin/sed -i '' -E "s/^APP_BUILD=.*/APP_BUILD=\"$NEW_BUILD\"/" sparkle.config
    source ./sparkle.config
fi
TAG="v$APP_VERSION"
echo "→ Репозиторий: $REPO · релиз $TAG (сборка $APP_BUILD)"

# 3. Создаём репозиторий, если его ещё нет
if ! gh repo view "$REPO" >/dev/null 2>&1; then
    echo "→ Создаю публичный репозиторий $REPO"
    gh repo create "$REPO" --public --description "Скриншотилка — снимки и запись экрана для macOS" >/dev/null
fi
# Релизам нужна хотя бы одна ветка/коммит — инициализируем пустой репозиторий README.
if ! gh api "repos/$REPO/commits" >/dev/null 2>&1; then
    echo "→ Инициализирую репозиторий (README)…"
    README_B64=$(printf '# Скриншотилка\n\nСнимки и запись экрана для macOS.\nГотовые сборки — во вкладке **Releases**. Обновления ставятся автоматически.' | base64 | tr -d '\n')
    gh api "repos/$REPO/contents/README.md" -X PUT \
        -f message="Initial commit" \
        -f content="$README_B64" >/dev/null
    sleep 2
fi

# 4. Сборка + упаковка + appcast (ссылки на ассеты этого релиза)
echo "→ Сборка…"; ./build.sh >/dev/null
DIST="dist"; rm -rf "$DIST"; mkdir -p "$DIST"
ZIP="$DIST/Screenshotka-$APP_VERSION.zip"
ditto -c -k --keepParent "build/Скриншотилка.app" "$ZIP"
Vendor/Sparkle/bin/generate_appcast "$DIST" \
    --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" >/dev/null
echo "  ✓ $ZIP + $DIST/appcast.xml"

# Красивый установочный DMG (app → Applications). Делаем ПОСЛЕ appcast, чтобы он не
# попал в фид Sparkle — обновления идут через .zip, а .dmg это для первой установки.
DMG="$DIST/Screenshotka-$APP_VERSION.dmg"
if command -v create-dmg >/dev/null; then
    ./make-dmg.sh >/dev/null 2>&1 && echo "  ✓ $DMG" || echo "  ⚠ DMG не собрался (пропускаю)"
else
    echo "  ⚠ create-dmg не установлен — DMG пропущен (brew install create-dmg)"; DMG=""
fi

# 5. Публикация релиза (пересоздаём, если тег уже есть)
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    gh release delete "$TAG" --repo "$REPO" --yes --cleanup-tag >/dev/null 2>&1 || true
fi
echo "→ Публикую релиз $TAG…"
ASSETS=("$ZIP" "$DIST/appcast.xml")
[ -n "$DMG" ] && [ -f "$DMG" ] && ASSETS+=("$DMG")
gh release create "$TAG" "${ASSETS[@]}" \
    --repo "$REPO" --title "$APP_VERSION" --notes "Скриншотилка $APP_VERSION" >/dev/null

# 6. Проверка: фид доступен
sleep 3
CODE=$(curl -s -o /dev/null -w "%{http_code}" -L "$SPARKLE_FEED_URL")
echo ""
if [ "$CODE" = "200" ]; then
    echo "✅ Готово. Фид обновлений доступен (HTTP 200):"
    echo "   $SPARKLE_FEED_URL"
    echo "   Теперь «Проверить обновления…» работает, друзья получают апдейты."
else
    echo "⚠️  Релиз создан, но фид пока отдаёт HTTP $CODE (GitHub мог не успеть)."
    echo "   Проверь через минуту: curl -IL $SPARKLE_FEED_URL"
fi