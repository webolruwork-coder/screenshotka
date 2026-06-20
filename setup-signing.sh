#!/bin/bash
# Создаёт стабильный самоподписанный code-signing сертификат в отдельном keychain.
# Нужен один раз. Благодаря стабильной подписи разрешение «Запись экрана»
# переживает пересборки (TCC опирается на Designated Requirement, а не на cdhash).
# Без sudo и без пароля логина — используется выделенный keychain с известным паролем.
set -e

if [ -f ./sparkle.config ]; then
    source ./sparkle.config
fi

IDENTITY="Screenshotka Dev"
KC_PW="screenshotka-dev"
KC="$HOME/Library/Keychains/screenshotka-signing.keychain-db"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Уже настроено?
#
# Важно: самоподписанный сертификат обычно показывается как
# CSSMERR_TP_NOT_TRUSTED и НЕ попадает в `find-identity -v` (valid only).
# Если проверять через `-v`, скрипт будет каждый раз пересоздавать сертификат,
# меняя certificate leaf в Designated Requirement — и macOS TCC снова запросит
# доступ к экрану/камере/микрофону. Поэтому проверяем наличие сертификата и
# приватного ключа без требования trust-valid статуса.
if security find-certificate -c "$IDENTITY" "$KC" >/dev/null 2>&1 &&
   security find-identity -p codesigning "$KC" 2>/dev/null | grep -q "$IDENTITY"; then
    LEAF_HASH=$(security find-certificate -c "$IDENTITY" -Z "$KC" 2>/dev/null | awk '/SHA-1 hash:/{print $3; exit}')
    if [ -n "${CODE_SIGN_CERT_SHA1:-}" ] && [ "$LEAF_HASH" != "$CODE_SIGN_CERT_SHA1" ]; then
        echo "✗ Найден другой certificate leaf для $IDENTITY: $LEAF_HASH" >&2
        echo "  Ожидался: $CODE_SIGN_CERT_SHA1" >&2
        echo "  Не пересоздаю подпись: иначе у пользователей снова слетят macOS-разрешения." >&2
        exit 1
    fi
    echo "✓ Сертификат уже существует: $IDENTITY ($LEAF_HASH) — пропускаю."
    exit 0
fi

if [ -n "${CODE_SIGN_CERT_SHA1:-}" ] && [ "${SCREENSHOTKA_ALLOW_NEW_SIGNING_IDENTITY:-}" != "1" ]; then
    echo "✗ Ожидаемый certificate leaf не найден: $CODE_SIGN_CERT_SHA1" >&2
    echo "  Нельзя автоматически создавать новый сертификат: это изменит designated requirement" >&2
    echo "  и сбросит macOS-разрешения у пользователей." >&2
    echo "  Восстановите $KC из бэкапа или, если вы сознательно начинаете новую линию подписи," >&2
    echo "  запустите: SCREENSHOTKA_ALLOW_NEW_SIGNING_IDENTITY=1 ./setup-signing.sh" >&2
    exit 1
fi

echo "→ Генерация самоподписанного сертификата (code signing)"
openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -nodes -subj "/CN=$IDENTITY" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/id.p12" -passout pass:p12pass -name "$IDENTITY" -legacy 2>/dev/null

echo "→ Выделенный keychain: $KC"
security delete-keychain "$KC" 2>/dev/null || true
security create-keychain -p "$KC_PW" "$KC"
security set-keychain-settings "$KC"                 # без авто-блокировки
security unlock-keychain -p "$KC_PW" "$KC"

echo "→ Импорт идентичности"
security import "$TMP/id.p12" -k "$KC" -P p12pass -T /usr/bin/codesign -A
# Разрешаем codesign использовать ключ без GUI-запроса.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PW" "$KC" >/dev/null 2>&1 || true

echo "→ Добавляю keychain в поисковый список"
EXISTING=$(security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"$//')
security list-keychains -d user -s "$KC" $EXISTING

echo
LEAF_HASH=$(security find-certificate -c "$IDENTITY" -Z "$KC" 2>/dev/null | awk '/SHA-1 hash:/{print $3; exit}')
echo "✓ Готово. Идентичность доступна для codesign: $IDENTITY"
echo "  Certificate leaf: $LEAF_HASH"
echo "  Теперь ./build.sh будет подписывать ей, и права не будут слетать после пересборки."
