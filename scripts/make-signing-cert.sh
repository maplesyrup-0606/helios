#!/usr/bin/env bash
# One-time: creates a self-signed code-signing certificate, "Helios Local Signing", in the
# login keychain. build-app.sh signs with it so macOS privacy grants (Full Disk Access)
# survive rebuilds. Remove it with Keychain Access if you no longer want it.
set -euo pipefail
NAME="Helios Local Signing"
if security find-identity -p codesigning | grep -q "\"$NAME\""; then
    echo "'$NAME' already exists"; exit 0
fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
PASS="helios-$RANDOM"
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
    -out "$TMP/cert.p12" -passout "pass:$PASS" 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
    -out "$TMP/cert.p12" -passout "pass:$PASS"
security import "$TMP/cert.p12" -k ~/Library/Keychains/login.keychain-db -P "$PASS" -T /usr/bin/codesign
# Trust it for code signing only (asks for your login password once).
security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db "$TMP/cert.pem"
echo "Created '$NAME'"
