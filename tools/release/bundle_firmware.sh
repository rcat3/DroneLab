#!/usr/bin/env bash
#
# Put a firmware build in the app, for it to keep boards in step with it:
#
#   tools/release/bundle_firmware.sh [build_dir]
#
# Copies build_dir's firmware (dronelab.bin, build-release-s3-175 by default:
# what tools/release/build_firmware.sh builds) to app/assets/firmware/, with
# firmware.json saying its version, as the board will say it, and the board
# it's for. Run it before building the app for a release; the app offers to
# update any board of that kind with an older release. Neither file is kept
# in git: an app built without them just doesn't offer updates.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
BUILD=$(realpath "${1:-$REPO/build-release-s3-175}")
OUT=$REPO/app/assets/firmware

BIN=$BUILD/dronelab.bin
DESC=$BUILD/project_description.json
[ -f "$BIN" ] && [ -f "$DESC" ] || { echo "No firmware built in $BUILD" >&2; exit 1; }
VERSION=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["project_version"])' "$DESC")
BOARD=$(sed -n 's/^BOARD:STRING=//p' "$BUILD/CMakeCache.txt")
# The board checks for this marker too, and won't take firmware without it
grep -qa "rcat-board:$BOARD" "$BIN" || { echo "$BIN isn't for $BOARD" >&2; exit 1; }
case "$VERSION" in
    *-dirty|*-g*) echo "Note: $VERSION isn't a release; boards compare by release number" >&2 ;;
esac

mkdir -p "$OUT"
cp "$BIN" "$OUT/firmware.bin"
SIZE=$(stat -c %s "$OUT/firmware.bin")
printf '{"version": "%s", "board": "%s", "size": %d}\n' "$VERSION" "$BOARD" "$SIZE" > "$OUT/firmware.json"
echo "Bundled $VERSION for $BOARD ($SIZE bytes) in $OUT"
