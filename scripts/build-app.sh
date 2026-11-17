#!/bin/zsh
# TriTab.app を組み立てる。
#
#   ./scripts/build-app.sh            # build/TriTab.app を作る（Apple Silicon + Intel のユニバーサル）
#   ./scripts/build-app.sh --install  # さらに /Applications にコピーして起動
#
# 環境変数:
#   SIGN_IDENTITY  署名に使う証明書名（配布用は release.sh が Developer ID を渡す）
#                  未指定なら、この Mac にあるものから次の順に選ぶ:
#                    1. Developer ID Application。配布版と署名の条件が同じになり、アクセシビリティの許可を
#                       配布版と共有できる（開発用ビルドを入れても、配布版の許可が外れない）。
#                       複数のチームの Developer ID があるときは、使うものを SIGN_IDENTITY で指定する
#                    2. scripts/setup-dev-signing.sh で作った「Swiper Local Dev」。ビルドし直しても許可は外れないが、
#                       配布版とは署名の条件が違うので、許可が効くのは最後に許可した方だけになる
#                    3. ad-hoc 署名（ビルドのたびにアクセシビリティの再許可が必要）
#   BUNDLE_ID      既定: io.github.ikora128.TriTab
#   VERSION        既定: 0.1.0
#   BUILD          ビルド番号（CFBundleVersion。Sparkle はこれで新旧を比べる）。既定: いまの日時（例 202611132130）
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID=${BUNDLE_ID:-io.github.ikora128.TriTab}
VERSION=${VERSION:-0.1.0}
BUILD=${BUILD:-$(date +%Y%m%d%H%M)}
DEV_KC=$HOME/.swiper-dev/swiper-dev.keychain-db
SIGN_NAME=${SIGN_IDENTITY:-}  # 表示用の名前
DEV_DEVID=                    # 開発用ビルドを Developer ID で署名するとき 1
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  # 「SHA-1 証明書名」の形で取り出す。同じ名前の証明書が複数あっても codesign が迷わないよう、署名には SHA-1 を使う
  DEVID=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/"Developer ID Application: / { split($1, f, " "); print f[2] " " $2; exit }' || true)
  if [[ -n "$DEVID" ]]; then
    SIGN_IDENTITY=${DEVID%% *}
    SIGN_NAME=${DEVID#* }
    DEV_DEVID=1
  elif [[ -f "$DEV_KC" ]]; then
    security unlock-keychain -p swiper-dev "$DEV_KC"
    SIGN_IDENTITY="Swiper Local Dev"
    SIGN_NAME=$SIGN_IDENTITY
  fi
fi
SIGN_IDENTITY=${SIGN_IDENTITY:--}
SIGN_NAME=${SIGN_NAME:-ad-hoc}
APP=build/TriTab.app

echo "==> ビルド (arm64)"
swift build -c release --arch arm64 >/dev/null
echo "==> ビルド (x86_64)"
swift build -c release --arch x86_64 >/dev/null

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
lipo -create \
  .build/arm64-apple-macosx/release/TriTab \
  .build/x86_64-apple-macosx/release/TriTab \
  -output "$APP/Contents/MacOS/TriTab"

# 自動アップデート（Sparkle）。SwiftPM が取ってきたユニバーサル版をそのまま入れる
FW="$APP/Contents/Frameworks/Sparkle.framework"
ditto .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework "$FW"
# XPC サービスはサンドボックスのアプリ用（Info.plist で有効にしない限り使われない）。ヘッダーは実行に不要
for d in XPCServices Headers PrivateHeaders Modules; do rm -rf "$FW/$d" "$FW/Versions/B/$d"; done

cp Resources/AppIcon.icns "$APP/Contents/Resources/"
sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/" -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" \
  Resources/Info.plist > "$APP/Contents/Info.plist"

echo "==> 署名 (${SIGN_NAME})"
# 配布用（Developer ID）は、公証のために Hardened Runtime と安全なタイムスタンプを付ける。
# 開発用に Developer ID で署名するときは、配布版と同じく Hardened Runtime を付け、
# タイムスタンプ（Apple のサーバーへの問い合わせ）は省く。
# 自己署名と ad-hoc には Hardened Runtime を付けない。チーム ID がない署名では、Hardened Runtime が
# Sparkle.framework の読み込みを拒否するため（different Team IDs）
if [[ -n "$DEV_DEVID" ]]; then
  SIGN_OPTS=(--options runtime --timestamp=none)
elif [[ "$SIGN_IDENTITY" == Developer\ ID* ]]; then
  SIGN_OPTS=(--options runtime --timestamp)
else
  SIGN_OPTS=(--timestamp=none)
fi
sign() { codesign --force "${SIGN_OPTS[@]}" --sign "$SIGN_IDENTITY" "$@"; }
# 内側から順に署名する（Sparkle は署名なしで配られているので、ここで自分の証明書で署名し直す）
sign "$FW/Versions/B/Autoupdate"
sign "$FW/Versions/B/Updater.app"
sign "$FW"
sign "$APP"
codesign --verify --deep --strict "$APP"

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
