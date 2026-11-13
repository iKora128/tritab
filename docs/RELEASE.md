# リリース手順（母艦の Mac で行う）

配布する TriTab は、Developer ID で署名して Apple の公証を通します。こうすると、ダウンロードした人が警告なしで開けます。作業は、最初の 1 回だけの準備と、リリースのたびの作業に分かれます。

## 最初の 1 回だけ

### 0. コードを持ってくる

```sh
git clone git@github.com:iKora128/tritab.git
cd tritab
```

Xcode（または Command Line Tools）と、GitHub CLI（`gh`）を使います。`gh auth status` でログイン済みか確認してください。

### 1. Developer ID の署名証明書を作る

Developer ID の証明書を作れるのは、Apple Developer Program のアカウント所有者（Account Holder）だけです。

1. Xcode を開き、「設定 › アカウント」で Apple ID を選ぶ
2. 「証明書を管理…」を押し、左下の ＋ から **Developer ID Application** を選ぶ
3. 確認する:

```sh
security find-identity -v -p codesigning | grep "Developer ID Application"
```

`Developer ID Application: 名前 (チームID)` と出れば準備完了です。

### 2. 公証用の認証情報を保存する

1. https://account.apple.com の「サインインとセキュリティ › App 用パスワード」で、パスワードを 1 つ発行する（名前は「TriTab notarize」など）
2. チーム ID を調べる（https://developer.apple.com/account の「メンバーシップの詳細」）
3. キーチェーンに保存する:

```sh
xcrun notarytool store-credentials TriTab \
  --apple-id "Apple ID のメールアドレス" \
  --team-id "チームID" \
  --password "発行した App 用パスワード"
```

`xcrun notarytool history --keychain-profile TriTab` がエラーにならなければ準備完了です。

### 3. Homebrew の tap をつくる（初回リリースのときだけ）

```sh
gh repo create iKora128/homebrew-tap --public --description "Homebrew tap for TriTab"
```

利用者は `brew install --cask ikora128/tap/tritab` で入れられるようになります。

## リリースのたび

1. `Resources/Info.plist` などを確認し、変更をコミットする
2. 実行する:

```sh
./scripts/release.sh 0.1.0             # build/release/ に DMG と ZIP を作るまで
./scripts/release.sh 0.1.0 --publish   # さらに GitHub Releases に下書きで公開する
```

このスクリプトは次の順に進みます。

- テストを実行する
- ユニバーサル（Apple Silicon + Intel）でビルドする
- Developer ID で署名し、公証する
- `stapler` で公証結果をアプリに貼り付ける
- DMG と ZIP を作る
- Gatekeeper が通すかを確認する

3. 下書きのリリースを確認して公開する（`gh release view v0.1.0 --web`）
4. `build/release/tritab.rb` を tap リポジトリの `Casks/tritab.rb` にコピーして push する

## うまくいかないとき

- **公証で失敗した**: `xcrun notarytool log <提出ID> --keychain-profile TriTab` で理由が見られます。
- **「開発元を確認できません」と出る**: `spctl --assess --type execute --verbose=2 build/TriTab.app` で、署名と公証の状態を確認します。
- **アップデート後にアクセシビリティの許可が外れる**: 署名の証明書かバンドル ID が前の版と違います。どちらも毎回同じにしてください。

## 補足: 開発用の署名

`scripts/setup-dev-signing.sh` は、開発中に作り直してもアクセシビリティの許可が外れないようにするための、自分の Mac 専用の自己署名証明書（「Swiper Local Dev」、旧名のまま）を作ります。配布には使えません。配布は必ず上の Developer ID で行います。
