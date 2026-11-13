# TriTab リリースまでの計画

TriTab — Three-finger tab control for Mac / 3本指で、タブを自在に。

最終更新: 2026-11-13

## いまの状態（できていること）

- **タブ操作**: 3本指スワイプ（左右で移動・下で閉じる・上で復元・指を離さずに左右へ往復）、3本指タップ（新しいタブ）、3本指クリック（⌘クリック）、4本指クリック（タブを復元）、親指＋2本指のピンチ（再読み込み）
- **誤動作対策**: スワイプ中の2本指スクロールによる「戻る／進む」を抑える。指を一瞬見失っても途切れない。App Nap に止められない
- **便利機能**:
  - ⌘単体で英数／かな、4本指タップで英かな切り替え（日本語を使う人だけ初期値でオン）
  - ノッチの棚（ファイル・画像・テキストの一時置き、メモ、Quick Look、サムネイル）
  - 5本指でディスプレイをスリープ
- **画面**: 設定画面（配色 B）と、はじめての案内。どちらも別プロセスで開き、閉じたら終わる
- **見た目**: アプリアイコン（夕焼け＋ノッチの棚）、メニューバーのアイコン（M4）
- **軽さ**: 常駐時のメモリは約 13 MB（Sparkle を入れる前は約 11 MB）
- **品質**: テスト 31 件（ジェスチャー判定・アプリ別のキー対応）
- **言語**: 日本語と英語（macOS の言語設定で切り替わる）
- **配布**: v0.1.0 を公開（2026-11-13）。Developer ID で署名・公証済みの DMG と ZIP を GitHub Releases に置き、Homebrew（`brew install --cask ikora128/tap/tritab`）でも入れられる。Sparkle で自動アップデート

## フェーズ 1: 仕上げ（公開前に必ずやる）

- [x] **英語対応**。いまは画面がすべて日本語なので、OSS として海外の人も使えるよう英語を用意する（日本語環境では日本語のまま）
- [x] **README を英語と日本語の 2 本立てにする**（`README.md` と `README.ja.md`）
- [ ] **README の一番上にスクリーンショットと動画（GIF）を置く**
- [x] **ライセンスを決めて `LICENSE` を置く**（MIT）
- [ ] **商標を確認する**: 「TriTab」で J-PlatPat（日本）と USPTO（米国）を検索する
- [ ] **ドメイン tritab.app を取得する**
- [x] **プライバシーの説明を書く**: キー入力やタッチの内容をどこにも送らないこと、通信はアップデートの確認だけであることを README に明記した
- [ ] **新しいユーザーで初回起動を通しで確認する**: macOS に別ユーザーを作り、案内画面 → 許可 → 試してみよう、を確かめる
- [ ] **いろいろな環境で確認する**:
  - [ ] 外付けの Magic Trackpad
  - [ ] 複数ディスプレイ（ノッチのない外部ディスプレイでの棚）
  - [ ] スリープ復帰
  - [ ] Intel Mac
  - [ ] macOS 13 / 14 / 15 / 26
- [ ] **対応アプリのショートカットを確認する**: Vivaldi・Opera・Zen・Orion・iTerm2 は未確認
- [ ] **確認用のフックの扱いを決める**: `TRITAB_DEBUG` のときだけ有効な、棚を操作するための通知（残すか消すか）

## フェーズ 2: 署名・公証・配布（母艦の Mac で）

手順の詳細は `docs/RELEASE.md` にあります。

- [x] 母艦に clone する
- [x] Developer ID Application の証明書を作る（もともとあった。2031-01-17 まで有効）
- [x] `notarytool` の認証情報を保存する（App Store Connect の API キー。プロファイル名 TriTab）
- [x] `./scripts/release.sh 0.1.0` で署名・公証済みの DMG と ZIP を作る
- [ ] 別の Mac（またはダウンロードし直したもの）で、警告なしで開けることを確認する（公開 URL から落とし直したものは `spctl` で「Notarized Developer ID」と確認済み。実機で開くのは未）
- [x] Homebrew の tap（`iKora128/homebrew-tap`）を作り、cask を置く
- [x] **自動アップデート（Sparkle）を入れる**: 更新情報（appcast）は GitHub Releases の最新リリースに添付する。署名鍵（EdDSA）はログインキーチェーンの「tritab」
- [ ] Sparkle の秘密鍵をパスワードマネージャーにバックアップする（`docs/RELEASE.md` の手順 3）
- [ ] （あとで）GitHub Actions でリリースを自動化する（証明書と公証の情報を Secrets に入れる）

## フェーズ 3: 公開

- [x] リポジトリを公開（Public）に切り替える（2026-11-13）
- [ ] 紹介ページを tritab.app に置く（GitHub Pages ＋ 独自ドメイン）。日本語と英語
- [x] v0.1.0 を GitHub Releases で公開する（2026-11-13）
- [ ] 告知する:
  - [ ] X（動画つき）
  - [ ] Qiita / Zenn の記事（「BetterTouchTool の 3本指タブ操作を単体アプリにした」）
  - [ ] Product Hunt
- [ ] Issues でフィードバックを受ける

## フェーズ 4: その後

- [ ] 公式の homebrew/cask に申請する（スター 75 以上で、ほかの人に申請してもらう）
- [ ] 任意のショートカットを記録して割り当てる機能（アプリ別の上書き）
- [ ] 設定の書き出し／取り込み（プリセットを共有できるように）
- [ ] 対応アプリを増やす
- [ ] メニューバーのアイコンで状態を示す（棚に中身があるとき、など）
- [ ] Quick Look を使ったあとのメモリ（約 +10 MB）を減らす。別プロセス化を検討する

## 気をつけること（リスク）

- **macOS の更新で動かなくなるかもしれない**: タッチの読み取りに非公開の仕組み（MultitouchSupport）を使っているため。新しい macOS のベータで毎回確認する
- **Mac App Store では配れない**: 非公開の仕組みを使っているため
- **アップデートで許可が外れないようにする**: 毎回同じ証明書と同じバンドル ID で署名する
- **ほかのアプリとの競合**: BetterTouchTool・Karabiner と同じジェスチャーやルールを使っていると二重に動く。設定画面と案内で知らせる

## 決まっていること

| 項目 | 内容 |
|---|---|
| 名前 | TriTab（Tri＝三本指 ＋ Try ＋ Tab） |
| 一言説明 | Three-finger tab control for Mac ／ 3本指で、タブを自在に。 |
| バンドル ID | io.github.ikora128.TriTab |
| ドメイン | tritab.app（未取得） |
| リポジトリ | github.com/iKora128/tritab（公開） |
| ライセンス | MIT |
| 配布 | GitHub Releases（DMG・ZIP）と Homebrew の tap（`ikora128/tap/tritab`） |
| アップデート | Sparkle。更新情報は `https://github.com/iKora128/tritab/releases/latest/download/appcast.xml` |
| アイコン | 夕焼けグラデーション ＋ 黒いノッチの棚 ＋ 3本指（`docs/design/app-icon.png`） |
| メニューバーのアイコン | 画面の枠 ＋ ノッチ ＋ 指（`docs/design/menubar-icons.png` の M4） |
| 配色 | 案 B：背景は macOS 標準、アクセントだけ夕焼け（`docs/design/settings-colors.html`） |
| 対応 OS | macOS 13 以降、Apple Silicon と Intel |
