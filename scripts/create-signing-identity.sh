#!/bin/bash
# Check or import the shared identity instead of creating a different key on each Mac.
set -euo pipefail

NAME=${MACSHOT_SIGN_IDENTITY:-"Gilad Peleg Local Signing"}
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -Fq -- "$NAME"; then
  echo "\"$NAME\" is valid for code signing."
  exit 0
fi

if [ "$#" -ne 1 ]; then
  echo "Import the shared .p12 backup from 1Password with:" >&2
  echo "  scripts/create-signing-identity.sh /path/to/identity.p12" >&2
  exit 1
fi

# Let Keychain ask for the backup password; keep it out of command arguments.
security import "$1" -k "$KEYCHAIN" -T /usr/bin/codesign
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
security find-certificate -c "$NAME" -p "$KEYCHAIN" > "$WORK/certificate.pem"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/certificate.pem"
security find-identity -v -p codesigning | grep -F -- "$NAME"
