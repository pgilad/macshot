# Security

## Report a vulnerability

Use [GitHub private vulnerability reporting](https://github.com/pgilad/macshot/security/advisories/new). Do not put details of a vulnerability in a public issue.

## Scope

In scope: anything that lets data leave the Mac, lets another app or a web page make macshot capture, save or show something without the user, reads files that the user did not choose, or recovers redacted pixels.

Out of scope: auto-redact patterns that miss text (they are a best effort), issues that need a compromised Mac or physical access, and vulnerabilities in macOS itself.

## Supported versions

Only the latest commit on `main`.

## Design

- App Sandbox on, with no network entitlement.
- Hardened runtime on every build (`scripts/bundle.sh`).
- No third-party code.
- The `macshot://` URL scheme is off by default and can only start an interactive capture or open Settings.
