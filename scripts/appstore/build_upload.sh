#!/usr/bin/env bash
# Archive (Release) → export (App Store) → upload to App Store Connect.
# No GUI. Uses the App Store Connect API key for auth + cloud signing.
#
# Required env (never printed): ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH
#   e.g.  set -a; . ~/dev/run-coach/.env; set +a
#
# Usage:
#   scripts/appstore/build_upload.sh [BUILD_NUMBER]
#   - BUILD_NUMBER omitted → auto = (latest uploaded build + 1) via API, else timestamp.
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT="$(pwd)"
PROJECT="ActivityVideoStudio.xcodeproj"
SCHEME="ActivityVideoStudio"
APP_ID="6764239734"
EXPORT_OPTS="$ROOT/scripts/appstore/ExportOptions.plist"
ASC="$ROOT/scripts/appstore/asc.py"
WORK="$(mktemp -d)/avs"
mkdir -p "$WORK"
ARCHIVE="$WORK/ActivityVideoStudio.xcarchive"
EXPORT_DIR="$WORK/export"

: "${ASC_KEY_ID:?set ASC_KEY_ID (source ~/dev/run-coach/.env)}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
[ -f "$ASC_KEY_PATH" ] || { echo "missing .p8 at $ASC_KEY_PATH"; exit 1; }

# --- build number ---
BUILD_NUMBER="${1:-}"
if [ -z "$BUILD_NUMBER" ]; then
  LATEST="$(python3 "$ASC" builds "$APP_ID" 2>/dev/null | awk 'NR==1{print $1}')"
  if [[ "$LATEST" =~ ^[0-9]+$ ]]; then BUILD_NUMBER=$((LATEST + 1)); else BUILD_NUMBER="$(date +%y%m%d%H%M)"; fi
fi
echo "==> build number: $BUILD_NUMBER"

# --- archive (Release) ---
echo "==> archiving (Release)…"
xcodebuild archive \
  -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  | tail -3

# --- export + upload (App Store, cloud-signed, API-key auth) ---
echo "==> exporting + uploading to App Store Connect…"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$EXPORT_OPTS" \
  -exportPath "$EXPORT_DIR" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  | tail -5

echo "==> uploaded build $BUILD_NUMBER. It will appear in App Store Connect as 'Processing'."
echo "    Check status:  python3 scripts/appstore/asc.py builds $APP_ID"
echo "    Then submit:   scripts/appstore/submit.sh   (after it shows VALID)"
rm -rf "$WORK" 2>/dev/null || true
