# Homebrew の cask のひな形。scripts/release.sh が __VERSION__ と __SHA256__ を埋めて build/release/tritab.rb に書き出す。
# 書き出したものを tap リポジトリ（github.com/iKora128/homebrew-tap の Casks/tritab.rb）に置く。
cask "tritab" do
  version "__VERSION__"
  sha256 "__SHA256__"

  url "https://github.com/iKora128/tritab/releases/download/v#{version}/TriTab-#{version}.zip"
  name "TriTab"
  desc "Control browser tabs with three-finger trackpad gestures"
  homepage "https://github.com/iKora128/tritab"

  livecheck do
    url :url
    strategy :github_latest
  end

  # アプリ自身が Sparkle で更新する
  auto_updates true
  depends_on macos: ">= :ventura"

  app "TriTab.app"

  uninstall quit: "io.github.ikora128.TriTab"

  zap trash: [
    "~/Library/Application Support/io.github.ikora128.TriTab",
    "~/Library/Caches/io.github.ikora128.TriTab",
    "~/Library/HTTPStorages/io.github.ikora128.TriTab",
    "~/Library/Preferences/io.github.ikora128.TriTab.plist",
  ]
end
