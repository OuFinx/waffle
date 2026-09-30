#!/bin/sh
# Optional, once per Mac: creates a self-signed "Waffle Local Signing" certificate in your login keychain.
# build.sh signs with it when it exists. macOS then recognises every rebuild as the same app, so Microphone and
# Screen & System Audio Recording permissions survive rebuilds (an ad-hoc signature changes with every build).
# The certificate never leaves this Mac; delete it in Keychain Access to undo.
set -e
NAME="Waffle Local Signing"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then echo "\"$NAME\" already exists"; exit 0; fi
TMP=$(mktemp -d)
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$NAME" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
# macOS keychain import needs the older PKCS#12 algorithms
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" -out "$TMP/id.p12" -passout pass:waffle 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" -out "$TMP/id.p12" -passout pass:waffle
security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P waffle -T /usr/bin/codesign
rm -rf "$TMP"
echo "created \"$NAME\"; run ./build.sh"
