#!/usr/bin/env bash
# Build a signed IPA and push it to Firebase App Distribution.
#
#   ./release-ios.sh "what changed in this build"
#
# Requires, all of which need an Apple Developer Program membership:
#   - a signing identity in the login keychain (Xcode > Settings > Accounts)
#   - ios/ExportOptions.plist with your teamID (copy the .example)
#   - an iOS app registered in the Firebase project, for its app id
set -euo pipefail
cd "$(dirname "$0")"

APP_ID="${AURA_IOS_APP_ID:-}"      # 1:475820602320:ios:...  from the Firebase console
GROUPS="pilot"
NOTES="${1:-$(git log -1 --pretty=%s)}"
ENV_FILE="$HOME/Workspace/RUA/rua-band-server/.env"

if ! security find-identity -v -p codesigning | grep -q 'valid identities found' ||
   security find-identity -v -p codesigning | grep -q '0 valid identities found'; then
  echo "No code-signing identity in the keychain."
  echo "iOS has no self-service signing: Apple issues the certificate and that"
  echo "needs a Developer Program membership. Sign in under Xcode > Settings >"
  echo "Accounts, then let Xcode create an Apple Distribution certificate."
  exit 1
fi
[ -f ios/ExportOptions.plist ] || { echo "ios/ExportOptions.plist missing — copy ExportOptions.plist.example and set teamID"; exit 1; }
[ -n "$APP_ID" ] || { echo "set AURA_IOS_APP_ID to the Firebase iOS app id"; exit 1; }

# Same build-time credential injection as Android: this repository is public,
# so the credential is never a literal in the source.
[ -f "$ENV_FILE" ] || { echo "missing $ENV_FILE"; exit 1; }
set -a; . "$ENV_FILE"; set +a
: "${API_AUTH_USER:?}" "${API_AUTH_PASS:?}"

flutter build ipa --release \
  --export-options-plist=ios/ExportOptions.plist \
  --dart-define=AURA_AUTH_USER="$API_AUTH_USER" \
  --dart-define=AURA_AUTH_PASS="$API_AUTH_PASS"

IPA=$(ls build/ios/ipa/*.ipa | head -1)
echo "built $IPA"

firebase appdistribution:distribute "$IPA" \
  --app "$APP_ID" \
  --groups "$GROUPS" \
  --release-notes "$NOTES"
