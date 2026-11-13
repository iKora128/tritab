#!/bin/zsh
# TriTab.app を組み立てる。
#
#   ./scripts/build-app.sh            # build/TriTab.app を作る（Apple Silicon + Intel のユニバーサル）
#   ./scripts/build-app.sh --install  # さらに /Applications にコピーして起動
#
# 環境変数:
#   SIGN_IDENTITY  署名に使う証明書名
#                  未指定なら、scripts/setup-dev-signing.sh で作った「Swiper Local Dev」があればそれを使い、
#                  なければ ad-hoc 署名（ビルドのたびにアクセシビリティの再許可が必要）
#   BUNDLE_ID      既定: io.github.ikora128.TriTab
#   VERSION        既定: 0.1.0
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID=${BUNDLE_ID:-io.github.ikora128.TriTab}
VERSION=${VERSION:-0.1.0}
BUILD=$(date +%Y%m%d%H%M)
DEV_KC=$HOME/.swiper-dev/swiper-dev.keychain-db
if [[ -z "${SIGN_IDENTITY:-}" && -f "$DEV_KC" ]]; then
  security unlock-keychain -p swiper-dev "$DEV_KC"
  SIGN_IDENTITY="Swiper Local Dev"
fi
SIGN_IDENTITY=${SIGN_IDENTITY:--}
APP=build/TriTab.app

echo "==> ビルド (arm64)"
swift build -c release --arch arm64 >/dev/null
echo "==> ビルド (x86_64)"
swift build -c release --arch x86_64 >/dev/null

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create \
  .build/arm64-apple-macosx/release/TriTab \
  .build/x86_64-apple-macosx/release/TriTab \
  -output "$APP/Contents/MacOS/TriTab"

cp Resources/AppIcon.icns "$APP/Contents/Resources/"
sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/" -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" \
  Resources/Info.plist > "$APP/Contents/Info.plist"

echo "==> 署名 (${SIGN_IDENTITY})"
# 配布用（Developer ID）は公証のために安全なタイムスタンプが必要。開発用は不要
if [[ "$SIGN_IDENTITY" == Developer\ ID* ]]; then TIMESTAMP=--timestamp; else TIMESTAMP=--timestamp=none; fi
codesign --force --options runtime $TIMESTAMP --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict "$APP"

lipo -info "$APP/Contents/MacOS/TriTab"
echo "==> $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x TriTab 2>/dev/null || true
  rm -rf /Applications/TriTab.app
  if [[ "$SIGN_IDENTITY" == "-" ]]; then
    # ad-hoc 署名はビルドごとに署名が変わり、古い許可が効かなくなる。許可を消して起動時に再度求めさせる
    tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
  fi
  cp -R "$APP" /Applications/
  open /Applications/TriTab.app
  echo "==> /Applications/TriTab.app を起動しました"
fi
