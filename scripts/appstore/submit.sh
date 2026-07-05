#!/usr/bin/env bash
# Attach latest build → set review notes (sample files) → submit for review. No GUI.
# Required env: ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_PATH  (e.g. source ~/dev/run-coach/.env)
# Usage: scripts/appstore/submit.sh [BUILD_NUMBER]   (default: latest uploaded VALID build)
set -euo pipefail
cd "$(dirname "$0")/../.."
APP_ID="6764239734"
: "${ASC_KEY_ID:?set ASC_KEY_ID (source ~/dev/run-coach/.env)}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID (source ~/dev/run-coach/.env)}"
BUILD="${1:-}"
if [ -z "$BUILD" ]; then
  LATEST_OUTPUT="$(python3 scripts/appstore/asc.py builds "$APP_ID")"
  LATEST_BUILD="$(printf '%s\n' "$LATEST_OUTPUT" | awk 'NF{print $1; exit}')"
  LATEST_STATE="$(printf '%s\n' "$LATEST_OUTPUT" | awk 'NF{print $2; exit}')"

  BUILD_OUTPUT="$(python3 scripts/appstore/asc.py builds "$APP_ID" --state VALID)"
  BUILD="$(printf '%s\n' "$BUILD_OUTPUT" | awk 'NF{print $1; exit}')"

  if [ -n "$LATEST_BUILD" ] && [ -n "$BUILD" ] && [ "$LATEST_BUILD" != "$BUILD" ]; then
    echo "warning: newer build $LATEST_BUILD is $LATEST_STATE; latest VALID build is $BUILD." >&2
    echo "warning: a newer build is still processing; refusing to submit an older build." >&2
    exit 1
  fi
  if [ -n "$LATEST_BUILD" ] && [ -z "$BUILD" ] && [ "$LATEST_STATE" != "VALID" ]; then
    echo "warning: newest build $LATEST_BUILD is $LATEST_STATE; no VALID build is available yet." >&2
    echo "warning: a newer build is still processing; refusing to submit an older build." >&2
    exit 1
  fi
  if [ -z "$BUILD" ]; then
    echo "no VALID App Store Connect build found for app $APP_ID" >&2
    exit 1
  fi
fi
echo "submitting build $BUILD for review…"
python3 scripts/appstore/asc.py submit "$APP_ID" "$BUILD" scripts/appstore/review_notes.txt
