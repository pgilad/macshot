#!/bin/bash
# Creates the "macshot Release Signing" certificate that .github/workflows/release.yaml signs
# with, and stores it in the "release" environment of the GitHub repository.
#
# Why: macOS ties the Screen Recording and Accessibility permissions to the code signature.
# If each release is signed with the same certificate, macOS keeps the permissions after an
# update. Without an Apple Developer ID the certificate is self-signed, so Gatekeeper still
# asks on first start.
#
# Run this once. A new certificate makes each user grant the permissions again, so make a
# new one only if the key leaks. The login keychain keeps a copy of the identity as a backup.
#
# Requires gh, logged in with admin access to the repository.
set -euo pipefail

NAME="macshot Release Signing"
REPO=${REPO:-pgilad/macshot}
ENVIRONMENT=release
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning "$KEYCHAIN" | grep -q "\"$NAME\""; then
  echo "\"$NAME\" is already in the login keychain. Delete it first to make a new one." >&2
  exit 1
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

echo "Limiting the \"$ENVIRONMENT\" environment of $REPO to v* tags…"
gh api --method PUT "repos/$REPO/environments/$ENVIRONMENT" --silent --input - <<'JSON'
{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
JSON
if [ -z "$(gh api "repos/$REPO/environments/$ENVIRONMENT/deployment-branch-policies" \
  --jq '.branch_policies[] | select(.name == "v*" and .type == "tag") | .id')" ]; then
  gh api --method POST "repos/$REPO/environments/$ENVIRONMENT/deployment-branch-policies" \
    --silent -f name='v*' -f type=tag
fi

echo "Storing the identity in the environment secrets…"
base64 < "$WORK/identity.p12" | gh secret set MACSHOT_SIGNING_P12 --repo "$REPO" --env "$ENVIRONMENT"
printf '%s' "$PASSWORD" | gh secret set MACSHOT_SIGNING_P12_PASSWORD --repo "$REPO" --env "$ENVIRONMENT"

# -T: codesign can use the key without a keychain prompt each time.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign
/usr/bin/openssl x509 -in "$WORK/cert.pem" -noout -fingerprint -sha1
echo "Done. Push a v* tag to release."
