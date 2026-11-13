#!/bin/zsh
# 配布用の TriTab をつくる:
#   テスト → ビルド → Developer ID で署名 → 公証 → DMG / ZIP → 更新情報（appcast.xml）→ (任意) GitHub Releases に下書きで公開
#
#   ./scripts/release.sh 0.1.0            # build/release/ に DMG・ZIP・appcast.xml・Homebrew の cask を作るところまで
#   ./scripts/release.sh 0.1.0 --publish  # さらに GitHub Releases に下書きで公開する
#
# 事前準備（1 回だけ。docs/RELEASE.md を参照）:
#   - キーチェーンに「Developer ID Application」証明書がある
#   - xcrun notarytool store-credentials で公証用の認証情報を保存してある（プロファイル名は NOTARY_PROFILE）
#   - Sparkle の署名鍵がキーチェーンにある（generate_keys --account tritab で作ったもの）
#   - リリースノートを packaging/release-notes/<バージョン>.md に書いてある
#
# 環境変数:
#   DEVELOPER_ID     署名に使う証明書（既定: "Developer ID Application"。複数あるときはフルネームで指定）
#   NOTARY_PROFILE   notarytool のキーチェーンプロファイル名（既定: TriTab）
#   SPARKLE_ACCOUNT  Sparkle の署名鍵のキーチェーン上の名前（既定: tritab）
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:?"バージョンを指定してください（例: ./scripts/release.sh 0.1.0）"}
PUBLISH=${2:-}
DEVELOPER_ID=${DEVELOPER_ID:-Developer ID Application}
NOTARY_PROFILE=${NOTARY_PROFILE:-TriTab}
SPARKLE_ACCOUNT=${SPARKLE_ACCOUNT:-tritab}
REPO=iKora128/tritab
APP=build/TriTab.app
OUT=build/release
ZIP=$OUT/TriTab-$VERSION.zip
DMG=$OUT/TriTab-$VERSION.dmg
APPCAST=$OUT/appcast.xml
NOTES=packaging/release-notes/$VERSION.md
SPARKLE_BIN=.build/artifacts/sparkle/Sparkle/bin

echo "==> 事前チェック"
security find-identity -v -p codesigning | grep -q "$DEVELOPER_ID" \
  || { echo "「$DEVELOPER_ID」の署名証明書が見つかりません（docs/RELEASE.md の手順 1）"; exit 1; }
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || { echo "notarytool のプロファイル「$NOTARY_PROFILE」が使えません（docs/RELEASE.md の手順 2。Apple の新しい規約に未同意のときもここで止まります）"; exit 1; }
if [[ -n "$(git status --porcelain)" ]]; then
  echo "コミットしていない変更があります。リリースはコミット済みの状態から作ってください"; exit 1
fi
[[ -f "$NOTES" ]] || { echo "リリースノート $NOTES がありません"; exit 1; }
swift package resolve >/dev/null
# アプリに入れた公開鍵と、キーチェーンの秘密鍵が対になっているか（違うと、配った更新を誰も受け取れない）
PUBLIC_KEY=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" Resources/Info.plist)
KEYCHAIN_PUBLIC_KEY=$("$SPARKLE_BIN/generate_keys" --account "$SPARKLE_ACCOUNT" -p 2>/dev/null || true)
[[ "$PUBLIC_KEY" == "$KEYCHAIN_PUBLIC_KEY" ]] \
  || { echo "Sparkle の署名鍵（キーチェーンの「$SPARKLE_ACCOUNT」）が Info.plist の SUPublicEDKey と合いません（docs/RELEASE.md の手順 3）"; exit 1; }
if [[ "$PUBLISH" == "--publish" ]]; then
  gh auth status >/dev/null 2>&1 || { echo "gh にログインしていません（gh auth login）"; exit 1; }
  if gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1; then
    echo "v$VERSION のリリースはすでにあります"; exit 1
  fi
  # 下書きのリリースはこのコミットを指すので、先に GitHub へ push しておく必要がある
  git fetch -q origin
  [[ -n "$(git branch -r --contains HEAD)" ]] \
    || { echo "いまのコミットが GitHub にありません。先に push してください"; exit 1; }
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

echo "==> ZIP（Homebrew と自動アップデート用）"
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

echo "==> 更新情報（appcast.xml）"
# アプリは https://github.com/$REPO/releases/latest/download/appcast.xml を見に行く（Info.plist の SUFeedURL）。
# 最新のリリースに appcast.xml を添付すれば、そのリリースを公開した瞬間に更新が届き始める
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
MIN_OS=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$APP/Contents/Info.plist")
ENCLOSURE=$("$SPARKLE_BIN/sign_update" --account "$SPARKLE_ACCOUNT" "$ZIP")  # sparkle:edSignature="…" length="…"
PUB_DATE=$(LC_ALL=C date -u +"%a, %d %b %Y %H:%M:%S +0000")
cat > "$APPCAST" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>TriTab</title>
    <link>https://github.com/$REPO</link>
    <description>TriTab updates</description>
    <item>
      <title>TriTab $VERSION</title>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <description sparkle:format="markdown"><![CDATA[
$(cat "$NOTES")
]]></description>
      <enclosure url="https://github.com/$REPO/releases/download/v$VERSION/TriTab-$VERSION.zip" type="application/octet-stream" $ENCLOSURE />
    </item>
  </channel>
</rss>
XML
xmllint --noout "$APPCAST"
# 更新情報そのものにも署名する（Info.plist の SURequireSignedFeed。署名のない更新情報はアプリが受け付けない）
"$SPARKLE_BIN/sign_update" --account "$SPARKLE_ACCOUNT" "$APPCAST"
"$SPARKLE_BIN/sign_update" --account "$SPARKLE_ACCOUNT" --verify "$APPCAST"
"$SPARKLE_BIN/sign_update" --account "$SPARKLE_ACCOUNT" --verify "$ZIP" \
  "$(sed -E 's/.*sparkle:edSignature="([^"]+)".*/\1/' <<< "$ENCLOSURE")"

ZIP_SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
# Homebrew の cask を、このバージョンの値で書き出す（tap リポジトリにコピーして使う）
sed -e "s/__VERSION__/$VERSION/" -e "s/__SHA256__/$ZIP_SHA/" packaging/homebrew/tritab.rb > "$OUT/tritab.rb"

echo "==> できあがり"
ls -lh "$OUT"
echo "ZIP の SHA-256: $ZIP_SHA"
echo "Homebrew の cask: $OUT/tritab.rb"

if [[ "$PUBLISH" == "--publish" ]]; then
  echo "==> GitHub Releases に下書きで公開"
  gh release create "v$VERSION" "$DMG" "$ZIP" "$APPCAST" --repo "$REPO" \
    --draft --target "$(git rev-parse HEAD)" --title "TriTab $VERSION" --notes-file "$NOTES"
  echo "下書きを確認して公開してください: gh release view v$VERSION --repo $REPO --web"
  echo "公開すると、appcast.xml を通じて既存のユーザーに更新が届きます"
fi
