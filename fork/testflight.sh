#!/bin/bash
# Builds the fork from fork-build and ships it to TestFlight.
#
#   fork/testflight.sh
#
# 1. Merges the fork's branches into fork-build (stops on a conflict).
# 2. Archives with release Xcode, numbering the build YYYYMMDD.HHMM.
# 3. Checks the archive, exports it with the fork's App Store profiles, uploads.
# 4. Waits until TestFlight has processed it.
#
# Env: ASC_ISSUER_ID and ASC_KEY_ID override the fork's App Store Connect IDs,
#      MARKETING_VERSION (default 18.7.0), DEVELOPER_DIR (default release Xcode).
set -euo pipefail

BRANCHES=(fix/xcode27-hostview fix/command-error-message tmux-launcher fix/emoji-row-fit fix/synchronized-output fix/padding-colour)
TEAM_ID=HXRC74AQZR
ASC_ISSUER_ID="${ASC_ISSUER_ID:-64a1d5c5-ddde-41e6-9f34-9a35c3d643ad}"
ASC_KEY_ID="${ASC_KEY_ID:-JTM5DPS5W7}"
MARKETING_VERSION="${MARKETING_VERSION:-18.7.0}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BUILD="$(date +%Y%m%d.%H%M)"
OUT="$ROOT/build/fork/$BUILD"
mkdir -p "$OUT"
step() { printf '\n==> %s\n' "$*"; }

step "Merging into fork-build"
[[ "$(git branch --show-current)" == fork-build ]] || { echo "Check out fork-build first."; exit 1; }
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || { echo "Working tree has changes; commit or stash them."; exit 1; }
for branch in "${BRANCHES[@]}"; do
  git merge --no-edit "$branch" >/dev/null || { echo "Merge of $branch conflicted; resolve it, then rerun."; exit 1; }
done
echo "fork-build at $(git rev-parse --short HEAD)"

step "Archiving build $BUILD ($MARKETING_VERSION)"
xcodebuild archive -project Blink.xcodeproj -scheme Blink -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$OUT/Blink.xcarchive" \
  -derivedDataPath "$ROOT/build/fork/DerivedData" \
  DEVELOPMENT_TEAM="$TEAM_ID" CURRENT_PROJECT_VERSION="$BUILD" MARKETING_VERSION="$MARKETING_VERSION" \
  > "$OUT/archive.log" 2>&1 || { grep -E ': error:' "$OUT/archive.log" | sort -u | head; echo "Archive failed; see $OUT/archive.log"; exit 1; }

APP="$OUT/Blink.xcarchive/Products/Applications/Blink.app"
[[ "$(plutil -extract CFBundleVersion raw "$APP/Info.plist")" == "$BUILD" ]] || { echo "Archive has the wrong build number."; exit 1; }
# The archive must match fork-build, not whatever an earlier build left behind.
for f in term.js term.css hterm_all.patches.js; do
  cmp -s "$APP/$f" "Resources/$f" || { echo "Archived $f differs from Resources/$f."; exit 1; }
done

step "Exporting"
# Homebrew's rsync breaks Xcode's IPA packaging, so export with the system PATH.
env PATH=/usr/bin:/bin:/usr/sbin:/sbin xcodebuild -exportArchive \
  -archivePath "$OUT/Blink.xcarchive" -exportPath "$OUT/export" \
  -exportOptionsPlist fork/ExportOptions.plist > "$OUT/export.log" 2>&1 \
  || { grep -i error "$OUT/export.log" | head; echo "Export failed; see $OUT/export.log"; exit 1; }

step "Uploading"
xcrun altool --upload-app -t ios --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" \
  -f "$OUT/export/Blink.ipa" > "$OUT/upload.log" 2>&1 \
  || { grep -E 'ERROR|error' "$OUT/upload.log" | head; echo "Upload failed; see $OUT/upload.log"; exit 1; }
DELIVERY="$(sed -n 's/.*Delivery UUID: \([0-9a-f-]*\).*/\1/p' "$OUT/upload.log" | head -1)"
echo "Delivery $DELIVERY"

step "Waiting for TestFlight processing"
ASC_KEY_ID="$ASC_KEY_ID" ASC_ISSUER_ID="$ASC_ISSUER_ID" ruby fork/asc_wait.rb "$DELIVERY" "$BUILD"

step "Build $BUILD is on TestFlight ($(git rev-parse --short HEAD))"
