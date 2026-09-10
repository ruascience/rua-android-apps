#!/usr/bin/env bash
# Build a signed release APK and push it to Firebase App Distribution.
#
#   ./release.sh "what changed in this build"
#
# Requires: firebase login (once), android/key.properties (signing), and the
# server credentials in ../../../rua-band-server/.env.
set -euo pipefail
cd "$(dirname "$0")"

APP_ID="1:475820602320:android:60c36b05333f547d5f7fd5"
GROUPS="pilot"
NOTES="${1:-$(git log -1 --pretty=%s)}"
ENV_FILE="$HOME/Workspace/RUA/rua-band-server/.env"

# The API credential is injected at build time, never committed: this repo is
# public. Without it the app builds fine and then answers 401 on every sync —
# which pauses the outbox rather than losing it, but is not what you want to
# hand a tester.
[ -f "$ENV_FILE" ] || { echo "missing $ENV_FILE — cannot bake in credentials"; exit 1; }
set -a; . "$ENV_FILE"; set +a
: "${API_AUTH_USER:?}" "${API_AUTH_PASS:?}"

[ -f android/key.properties ] || {
  echo "android/key.properties missing — the build would be signed with the DEBUG key."
  echo "A debug-signed build cannot be upgraded to a real release; testers would"
  echo "have to uninstall, losing their local database. Refusing."
  exit 1
}

flutter build apk --release \
  --dart-define=AURA_AUTH_USER="$API_AUTH_USER" \
  --dart-define=AURA_AUTH_PASS="$API_AUTH_PASS"

APK=build/app/outputs/flutter-apk/app-release.apk

# Confirm what we are about to hand out is signed with the upload key and not
# the debug one. `apksigner` names the certificate; the debug key is
# CN=Android Debug.
BT=$(ls -d "$HOME/Library/Android/sdk/build-tools/"* | sort -V | tail -1)
DN=$("$BT/apksigner" verify --print-certs "$APK" | grep -m1 'Signer #1 certificate DN')
echo "$DN"
case "$DN" in
  *"Android Debug"*) echo "refusing to distribute a debug-signed build"; exit 1 ;;
esac

firebase appdistribution:distribute "$APK" \
  --app "$APP_ID" \
  --groups "$GROUPS" \
  --release-notes "$NOTES"
