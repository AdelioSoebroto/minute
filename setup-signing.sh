#!/bin/bash
# One-time: create a local code-signing identity called "Minute Local" in your login keychain.
# Why: macOS remembers permissions (microphone, meeting audio, folders, Word) by the app's signature. An ad-hoc signature changes on
# every build, so macOS would ask again after each rebuild. With this identity the signature stays the same, so each permission is asked once.
# The certificate never leaves this Mac and is only used to sign Minute. Run it yourself; it asks for nothing but your keychain access.
set -e
if security find-identity -p codesigning | grep -q '"Minute Local"'; then echo "\"Minute Local\" already exists."; exit 0; fi
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cat > "$T/o.cnf" <<CNF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=Minute Local
[ext]
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
basicConstraints=critical,CA:false
CNF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout "$T/k.pem" -out "$T/c.pem" -days 3650 -config "$T/o.cnf" 2>/dev/null
PASS=$(uuidgen)
/usr/bin/openssl pkcs12 -export -inkey "$T/k.pem" -in "$T/c.pem" -out "$T/m.p12" -passout "pass:$PASS" 2>/dev/null
security import "$T/m.p12" -k ~/Library/Keychains/login.keychain-db -P "$PASS" -T /usr/bin/codesign >/dev/null
echo "Created \"Minute Local\". Now run ./build.sh deploy."
