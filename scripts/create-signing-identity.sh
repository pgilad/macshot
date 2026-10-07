#!/bin/bash
# Creates a self-signed code signing certificate, "macshot Local Signing", in the login keychain.
#
# Why: macOS ties the Screen Recording and Accessibility permissions to the code signature.
# An ad-hoc signature changes with each build, so macOS forgets the permissions after each
# rebuild. A stable certificate keeps them across rebuilds.
#
# macOS asks for your login password once, to trust the certificate for code signing.
# The private key never leaves this Mac. Run this once on each Mac.
set -euo pipefail

NAME="macshot Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  echo "\"$NAME\" already exists and is valid for code signing."
  exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
PASSWORD=$(/usr/bin/openssl rand -hex 16)

cat > "$WORK/cert.conf" <<CONF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = $NAME
[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CONF

/usr/bin/openssl req -x509 -newkey rsa:3072 -nodes -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.conf" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/identity.p12" -passout "pass:$PASSWORD" -name "$NAME"

# -T: codesign can use the key without a keychain prompt each time.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign
echo "Trusting the certificate for code signing (macOS asks for your password)…"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

security find-identity -v -p codesigning | grep "\"$NAME\""
echo "Done. Build with: make install"
