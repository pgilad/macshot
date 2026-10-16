#!/bin/bash
# Store the shared signing backup in GitHub instead of creating a separate release key.
set -euo pipefail

NAME="Gilad Peleg Local Signing"
REPO=${REPO:-pgilad/macshot}
ENVIRONMENT=release

if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
  echo "Usage: scripts/configure-release-signing.sh /path/to/gilad-peleg-local-signing.p12" >&2
  exit 1
fi

# Read from the terminal so the password stays out of shell history and command arguments.
IFS= read -r -s -p "Shared .p12 backup password: " PASSWORD < /dev/tty
printf '\n' > /dev/tty

# Check the password and certificate name before changing any GitHub secrets.
SUBJECT=$(/usr/bin/openssl pkcs12 -in "$1" -clcerts -nokeys -passin fd:3 3<<< "$PASSWORD" \
  | /usr/bin/openssl x509 -noout -subject -nameopt RFC2253)
if ! printf '%s\n' "$SUBJECT" | grep -Eq "(^subject= *|,)CN=$NAME(,|$)"; then
  echo "The backup must contain the shared $NAME certificate." >&2
  exit 1
fi

echo "Limiting the \"$ENVIRONMENT\" environment of $REPO to v* tags…"
gh api --method PUT "repos/$REPO/environments/$ENVIRONMENT" --silent --input - <<'JSON'
{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
JSON
if [ -z "$(gh api "repos/$REPO/environments/$ENVIRONMENT/deployment-branch-policies" \
  --jq '.branch_policies[] | select(.name == "v*" and .type == "tag") | .id')" ]; then
  gh api --method POST "repos/$REPO/environments/$ENVIRONMENT/deployment-branch-policies" \
    --silent -f name='v*' -f type=tag
fi

echo "Storing the shared identity in the environment secrets…"
base64 < "$1" | gh secret set MACSHOT_SIGNING_P12 --repo "$REPO" --env "$ENVIRONMENT"
printf '%s' "$PASSWORD" | gh secret set MACSHOT_SIGNING_P12_PASSWORD --repo "$REPO" --env "$ENVIRONMENT"
unset PASSWORD
echo "Done. Releases and local builds now use the same signing identity."
