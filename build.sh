#!/bin/bash
# Сборка Скриншотилка.app напрямую через swiftc (без полного Xcode).
set -e
cd "$(dirname "$0")"

APP_NAME="Скриншотилка"
EXEC_NAME="Screenshotka"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
SDK="$(xcrun --show-sdk-path)"

# Конфигурация авто-обновлений (версия, публичный ключ, URL фида).
source ./sparkle.config
SPARKLE_FW="Vendor/Sparkle/Sparkle.framework"

echo "→ Очистка"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "→ Компиляция (SDK: $SDK)"
# -O + -wmo: whole-module optimization (кросс-файловый инлайнинг/специализация дженериков)
#            → быстрее рантайм и компактнее бинарь на Apple Silicon.
# -dead_strip: линкер выкидывает недостижимый код.
swiftc -O -wmo \
  Sources/Screenshotka/*.swift \
  -sdk "$SDK" \
  -target arm64-apple-macos14.0 \
  -framework AppKit -framework CoreImage -framework Carbon -framework ScreenCaptureKit \
  -F "$PWD/Vendor/Sparkle" -framework Sparkle \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -Xlinker -dead_strip \
  -o "$APP/Contents/MacOS/$EXEC_NAME"

echo "→ Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>$EXEC_NAME</string>
    <key>CFBundleIdentifier</key><string>com.local.screenshotka</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleDevelopmentRegion</key><string>ru</string>
    <key>CFBundleLocalizations</key><array><string>ru</string><string>en</string><string>es</string></array>
    <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
    <key>CFBundleVersion</key><string>$APP_BUILD</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>NSMicrophoneUsageDescription</key><string>Запись звука с микрофона во время видеозахвата экрана.</string>
    <key>NSCameraUsageDescription</key><string>Показ камеры в углу записи экрана.</string>
    <key>NSHumanReadableCopyright</key><string>Скриншотилка</string>
    <key>SUFeedURL</key><string>$SPARKLE_FEED_URL</string>
    <key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUScheduledCheckInterval</key><integer>86400</integer>
</dict>
</plist>
PLIST

echo "→ Иконка приложения"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "→ Локализации (.lproj)"
for lp in Resources/*.lproj; do
    [ -d "$lp" ] && cp -R "$lp" "$APP/Contents/Resources/"
done

echo "→ Встраивание Sparkle.framework"
mkdir -p "$APP/Contents/Frameworks"
cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/"

# Тонкий arm64: убираем x86_64-срез из всех Mach-O Sparkle (на Apple Silicon не нужен)
# → меньше размер приложения и загрузки. Делаем ДО подписи (подпись ниже всё переподпишет).
echo "→ Sparkle → только arm64"
while IFS= read -r f; do
    if lipo -archs "$f" 2>/dev/null | grep -q x86_64; then
        lipo -thin arm64 "$f" -output "$f" 2>/dev/null || true
    fi
done < <(find "$APP/Contents/Frameworks/Sparkle.framework" -type f)

# Стабильная подпись сохраняет разрешения TCC (экран/камера/микрофон) между
# сборками: macOS опирается на стабильный Designated Requirement
# (identifier + certificate leaf), а не на меняющийся cdhash.
#
# Важно: НЕ откатываемся молча на ad-hoc и НЕ делаем `tccutil reset`.
# Ad-hoc подпись меняется от сборки к сборке и заставляет macOS снова просить
# разрешения. Если сертификата нет, setup-signing.sh восстановит его только для
# новой линии подписи; при зафиксированном CODE_SIGN_CERT_SHA1 сборка упадёт,
# чтобы случайно не выпустить обновление с другим certificate leaf.
SIGN_KC="$HOME/Library/Keychains/screenshotka-signing.keychain-db"
SIGN_ID="Screenshotka Dev"
if ! security find-certificate -c "$SIGN_ID" "$SIGN_KC" >/dev/null 2>&1 ||
   ! security find-identity -p codesigning "$SIGN_KC" 2>/dev/null | grep -q "$SIGN_ID"; then
    echo "→ Стабильный сертификат не найден — создаю"
    ./setup-signing.sh
fi

security unlock-keychain -p "screenshotka-dev" "$SIGN_KC" >/dev/null 2>&1 || true
SIGN_HASH=$(security find-certificate -c "$SIGN_ID" -Z "$SIGN_KC" 2>/dev/null | awk '/SHA-1 hash:/{print $3; exit}')
if [ -z "$SIGN_HASH" ]; then
    echo "✗ Не удалось найти сертификат: $SIGN_ID в $SIGN_KC" >&2
    exit 1
fi
if [ -n "${CODE_SIGN_CERT_SHA1:-}" ] && [ "$SIGN_HASH" != "$CODE_SIGN_CERT_SHA1" ]; then
    echo "✗ Найден другой сертификат подписи: $SIGN_HASH" >&2
    echo "  Ожидался: $CODE_SIGN_CERT_SHA1" >&2
    echo "  Нельзя выпускать обновление с другим certificate leaf: у пользователей слетят macOS-разрешения." >&2
    exit 1
fi

echo "→ Подпись стабильным сертификатом: $SIGN_ID ($SIGN_HASH)"
# Sparkle нужно переподписать ТЕМ ЖЕ сертификатом, что и приложение: его XPC-сервисы
# проверяют, что главное приложение и хелперы подписаны одним удостоверением (Team).
# Подписываем изнутри наружу (Apple рекомендует это вместо --deep), сохраняя
# entitlements/flags хелперов Sparkle.
FWP="$APP/Contents/Frameworks/Sparkle.framework"
SIGN="codesign --force --sign $SIGN_HASH --keychain $SIGN_KC"
for comp in \
    "Versions/B/XPCServices/Installer.xpc" \
    "Versions/B/XPCServices/Downloader.xpc" \
    "Versions/B/Autoupdate" \
    "Versions/B/Updater.app"; do
    $SIGN --preserve-metadata=entitlements,flags "$FWP/$comp"
done
$SIGN "$FWP"
codesign --force --sign "$SIGN_HASH" --keychain "$SIGN_KC" "$APP"
echo "✓ Готово: $APP"
echo "  Разрешения «Запись экрана», «Камера» и «Микрофон» сохраняются между сборками."
