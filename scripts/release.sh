#!/bin/zsh
# 配布用の TriTab をつくる: テスト → ビルド → Developer ID で署名 → 公証 → DMG / ZIP → (任意) GitHub Releases に公開
#
#   ./scripts/release.sh 0.1.0            # build/release/ に DMG と ZIP を作るところまで
#   ./scripts/release.sh 0.1.0 --publish  # さらに GitHub Releases に下書きで公開し、Homebrew の cask を更新
#
# 事前準備（1 回だけ。docs/RELEASE.md を参照）:
#   - キーチェーンに「Developer ID Application」証明書がある
#   - xcrun notarytool store-credentials で公証用の認証情報を保存してある（プロファイル名は NOTARY_PROFILE）
#
# 環境変数:
#   DEVELOPER_ID     署名に使う証明書（既定: "Developer ID Application"。複数あるときはフルネームで指定）
#   NOTARY_PROFILE   notarytool のキーチェーンプロファイル名（既定: TriTab）
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:?"バージョンを指定してください（例: ./scripts/release.sh 0.1.0）"}
PUBLISH=${2:-}
DEVELOPER_ID=${DEVELOPER_ID:-Developer ID Application}
NOTARY_PROFILE=${NOTARY_PROFILE:-TriTab}
APP=build/TriTab.app
OUT=build/release
ZIP=$OUT/TriTab-$VERSION.zip
DMG=$OUT/TriTab-$VERSION.dmg

echo "==> 事前チェック"
security find-identity -v -p codesigning | grep -q "$DEVELOPER_ID" \
  || { echo "「$DEVELOPER_ID」の署名証明書が見つかりません（docs/RELEASE.md の手順 1）"; exit 1; }
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || { echo "notarytool のプロファイル「$NOTARY_PROFILE」が見つかりません（docs/RELEASE.md の手順 2）"; exit 1; }
if [[ -n "$(git status --porcelain)" ]]; then
  echo "コミットしていない変更があります。リリースはコミット済みの状態から作ってください"; exit 1
fi

echo "==> テスト"
./scripts/test.sh

echo "==> ビルドと署名（$DEVELOPER_ID）"
SIGN_IDENTITY="$DEVELOPER_ID" VERSION="$VERSION" ./scripts/build-app.sh
codesign --verify --deep --strict --verbose=2 "$APP"

rm -rf "$OUT" && mkdir -p "$OUT"

echo "==> 公証（数分かかります）"
ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
rm "$OUT/notarize.zip"

echo "==> ZIP（Homebrew 用）"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> DMG（手で入れる人用。アプリと「アプリケーション」へのリンクを並べる）"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "TriTab" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

echo "==> 確認（Gatekeeper が通すか）"
spctl --assess --type execute --verbose=2 "$APP"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

ZIP_SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
echo "==> できあがり"
ls -lh "$OUT"
echo "ZIP の SHA-256: $ZIP_SHA"

# Homebrew の cask を、このバージョンの値で書き出す（tap リポジトリにコピーして使う）
sed -e "s/__VERSION__/$VERSION/" -e "s/__SHA256__/$ZIP_SHA/" packaging/homebrew/tritab.rb > "$OUT/tritab.rb"
echo "Homebrew の cask: $OUT/tritab.rb"

if [[ "$PUBLISH" == "--publish" ]]; then
  echo "==> GitHub Releases に下書きで公開"
  gh release create "v$VERSION" "$DMG" "$ZIP" \
    --draft --title "TriTab $VERSION" \
    --notes "TriTab $VERSION — Three-finger tab control for Mac / 3本指で、タブを自在に。"
  echo "下書きを確認して公開してください: gh release view v$VERSION --web"
fi
