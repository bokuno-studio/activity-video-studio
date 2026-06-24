#!/usr/bin/env bash
# Attach latest build → set review notes (sample files) → submit for review. No GUI.
# Required env: ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_PATH  (e.g. source ~/dev/run-coach/.env)
# Usage: scripts/appstore/submit.sh [BUILD_NUMBER]   (default: latest uploaded VALID build)
set -euo pipefail
cd "$(dirname "$0")/../.."
APP_ID="6764239734"
: "${ASC_KEY_ID:?set ASC_KEY_ID (source ~/dev/run-coach/.env)}"
BUILD="${1:-$(python3 scripts/appstore/asc.py builds "$APP_ID" | awk 'NR==1{print $1}')}"
echo "submitting build $BUILD for review…"
python3 scripts/appstore/asc.py submit "$APP_ID" "$BUILD" scripts/appstore/review_notes.txt
