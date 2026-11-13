#!/bin/zsh
# 開発用の自己署名証明書「Swiper Local Dev」を専用キーチェーン (~/.swiper-dev) に作る。
# これで署名すると、ビルドし直してもアクセシビリティの許可が外れない（ad-hoc だと毎回外れる）。
# ログインキーチェーンには何も入れない。消すときは:
#   security delete-keychain ~/.swiper-dev/swiper-dev.keychain-db && rm -rf ~/.swiper-dev
set -euo pipefail
D=$HOME/.swiper-dev
KC=$D/swiper-dev.keychain-db
PW=swiper-dev
mkdir -p $D
if [[ ! -f $KC ]]; then
  cd $D
  cat > cert.cnf <<'CNF'
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=Swiper Local Dev
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF
  openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -config cert.cnf 2>/dev/null
  openssl pkcs12 -export -legacy -inkey key.pem -in cert.pem -out id.p12 -passout pass:$PW -name "Swiper Local Dev" 2>/dev/null \
    || openssl pkcs12 -export -inkey key.pem -in cert.pem -out id.p12 -passout pass:$PW -name "Swiper Local Dev"
  security create-keychain -p $PW $KC
  security set-keychain-settings $KC
  security unlock-keychain -p $PW $KC
  security import id.p12 -k $KC -P $PW -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple: -s -k $PW $KC >/dev/null 2>&1
  rm -f key.pem id.p12
fi
# codesign が見つけられるように検索リストへ追加
CUR=($(security list-keychains -d user | tr -d '"'))
if [[ ! " ${CUR[*]} " == *" $KC "* ]]; then
  security list-keychains -d user -s "${CUR[@]}" $KC
fi
security unlock-keychain -p $PW $KC
echo "==> 署名用 ID「Swiper Local Dev」を用意しました"
