# リリース手順（母艦の Mac で行う）

配布する TriTab は、Developer ID で署名して Apple の公証を通します。こうすると、ダウンロードした人が警告なしで開けます。アップデートは Sparkle で配ります。作業は、最初の 1 回だけの準備と、リリースのたびの作業に分かれます。

## 最初の 1 回だけ

母艦の Mac では 1〜3 は済んでいます（2026-11-13）。別の Mac でリリースするときだけ、もう一度やります。

### 0. コードを持ってくる

```sh
git clone https://github.com/iKora128/tritab.git
cd tritab
```

Xcode（または Command Line Tools）と、GitHub CLI（`gh`）を使います。`gh auth status` でログイン済みか確認してください。

### 1. Developer ID の署名証明書

Developer ID の証明書を作れるのは、Apple Developer Program のアカウント所有者（Account Holder）だけです。個人のチーム（BMZ4QY62TB）のものを使います。会社のチームのものではありません。

1. Xcode を開き、「設定 › アカウント」で Apple ID を選ぶ
2. 「証明書を管理…」を押し、左下の ＋ から **Developer ID Application** を選ぶ
3. 確認する:

```sh
security find-identity -v -p codesigning | grep "Developer ID Application"
```

`Developer ID Application: Daichi Nagashima (BMZ4QY62TB)` と出れば準備完了です（有効期限は 2031-01-17）。

### 2. 公証用の認証情報

App Store Connect の API キー（チームキー、Developer 権限で十分）を使います。母艦では、ほかのアプリと共通の公証用キーを `TriTab` という名前で保存してあります。

```sh
xcrun notarytool store-credentials TriTab \
  --key <AuthKey_XXXXXXXXXX.p8 のパス> \
  --key-id <キー ID> \
  --issuer <Issuer ID>
```

キー ID と Issuer ID は App Store Connect の「ユーザとアクセス › 統合 › App Store Connect API › チームキー」にあります。キーのファイル（.p8）は作成時に 1 回しかダウンロードできません。リポジトリには入れないでください。

`xcrun notarytool history --keychain-profile TriTab` がエラーにならなければ準備完了です。

### 3. Sparkle の署名鍵

アップデートの配布物に付ける署名（EdDSA）の鍵です。秘密鍵はログインキーチェーンに「tritab」という名前で入っていて、公開鍵は `Resources/Info.plist` の `SUPublicEDKey` に書いてあります。

```sh
swift package resolve
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account tritab -p   # 公開鍵を表示する（Info.plist と同じなら OK）
```

**秘密鍵は必ずバックアップしてください。** なくすと、配ったアプリにアップデートを届けられなくなります（利用者に手で入れ直してもらうしかなくなります）。

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account tritab -x ~/Desktop/tritab-sparkle-key.txt
# 中身をパスワードマネージャーに保存し、ファイルは消す
rm ~/Desktop/tritab-sparkle-key.txt
```

別の Mac でリリースするときは、`generate_keys --account tritab -f <ファイル>` で取り込みます。

### 4. Homebrew の tap

`iKora128/homebrew-tap`（公開）の `Casks/tritab.rb` が cask です。利用者は `brew install --cask ikora128/tap/tritab` で入れます。

## リリースのたび

1. バージョンを決め、`packaging/release-notes/<バージョン>.md` にリリースノートを書く（英語と日本語）。GitHub のリリースページと、アップデートの画面の両方に出ます
2. 変更をコミットして GitHub に push する
3. 実行する:

```sh
./scripts/release.sh 0.2.0             # build/release/ に DMG・ZIP・appcast.xml・cask を作るまで
./scripts/release.sh 0.2.0 --publish   # さらに GitHub Releases に下書きで公開する
```

このスクリプトは次の順に進みます。

- 証明書・公証の認証情報・Sparkle の鍵がそろっているかを確かめる
- テストを実行する
- ユニバーサル（Apple Silicon + Intel）でビルドし、Sparkle を含めて Developer ID で署名する
- 公証し、`stapler` で公証結果をアプリに貼り付ける
- ZIP（Homebrew とアップデート用）と DMG（手で入れる人用）を作る
- Gatekeeper が通すかを確かめる
- 更新情報 `appcast.xml` を作り、ZIP と appcast.xml の両方に Sparkle の署名を付ける

4. 下書きのリリースを確認して公開する（`gh release view v0.2.0 --repo iKora128/tritab --web`）。公開した時点で、`appcast.xml` を通じて既存の利用者にアップデートが届き始めます
5. `build/release/tritab.rb` を tap リポジトリの `Casks/tritab.rb` にコピーして push する

### アップデートが届く仕組み

アプリは `https://github.com/iKora128/tritab/releases/latest/download/appcast.xml`（`Info.plist` の `SUFeedURL`）を見に行きます。これは「最新のリリースに添付された appcast.xml」を指すので、リリースに必ず appcast.xml を添付してください（`release.sh --publish` は自動で添付します）。下書きやプレリリースは「最新」に数えられません。

アプリは署名のない appcast.xml を受け付けません（`SURequireSignedFeed`）。手で書き換えたら、`sign_update --account tritab appcast.xml` で署名し直してください。

## うまくいかないとき

- **公証が「A required agreement is missing or has expired」（403）で止まる**: Apple が規約を更新しています。https://developer.apple.com/account を開き、右上で個人のチーム（Daichi Nagashima）を選んで、新しい Apple Developer Program License Agreement に同意してください。反映まで数分かかることがあります。
- **公証で失敗した**: `xcrun notarytool log <提出ID> --keychain-profile TriTab` で理由が見られます。
- **「開発元を確認できません」と出る**: `spctl --assess --type execute --verbose=2 build/TriTab.app` で、署名と公証の状態を確認します。
- **アップデート後にアクセシビリティの許可が外れる**: 署名の証明書かバンドル ID が前の版と違います。どちらも毎回同じにしてください。
- **「Sparkle の署名鍵が Info.plist の SUPublicEDKey と合いません」**: キーチェーンに鍵がないか、違う鍵です。手順 3 のバックアップから取り込んでください。鍵を作り直して `SUPublicEDKey` を変えると、それより前の版の利用者にはアップデートが届きません。

## 補足: 開発用の署名

`scripts/setup-dev-signing.sh` は、開発中に作り直してもアクセシビリティの許可が外れないようにするための、自分の Mac 専用の自己署名証明書（「Swiper Local Dev」、旧名のまま）を作ります。配布には使えません。配布は必ず上の Developer ID で行います。

開発用の署名には Hardened Runtime を付けません。チーム ID のない署名だと、Hardened Runtime が Sparkle.framework の読み込みを拒否するためです。配布用（Developer ID）には付けます（公証に必要です）。
