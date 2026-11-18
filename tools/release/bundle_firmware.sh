#!/usr/bin/env bash
#
# Put a firmware build in the app, for it to keep boards in step with it:
#
#   tools/release/bundle_firmware.sh [--dev] [build_dir]
#
# Copies build_dir's firmware (dronelab.bin, build-release-s3-175 by default:
# what tools/release/build_firmware.sh builds) to app/assets/firmware/, with
# firmware.json saying its version, as the board will say it, and the board
# it's for. Run it before building the app for a release; the app offers to
# update any board of that kind with an older release. Neither file is kept
# in git: an app built without them just doesn't offer updates.
#
# The firmware has to be a release: built from a release's tag (vX.Y.Z),
# with nothing changed, so it says exactly that version. Built before the
# tag, or with changes, it says something like v0.9.6-3-gabc123-dirty, and
# the app would take the boards on the real release for newer than its own.
# See the release checklist in docs/development/README.md. --dev takes any
# build, for trying updates out.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
DEV=0
if [ "${1:-}" = "--dev" ]; then
    DEV=1
    shift
fi
BUILD=$(realpath "${1:-$REPO/build-release-s3-175}")
OUT=$REPO/app/assets/firmware

BIN=$BUILD/dronelab.bin
DESC=$BUILD/project_description.json
[ -f "$BIN" ] && [ -f "$DESC" ] || { echo "No firmware built in $BUILD" >&2; exit 1; }
VERSION=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["project_version"])' "$DESC")
BOARD=$(sed -n 's/^BOARD:STRING=//p' "$BUILD/CMakeCache.txt")
# The board checks for this marker too, and won't take firmware without it
grep -qa "rcat-board:$BOARD" "$BIN" || { echo "$BIN isn't for $BOARD" >&2; exit 1; }
if ! [[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    if [ "$DEV" = 0 ]; then
        echo "$VERSION isn't a release (vX.Y.Z): build it from the release's tag, with nothing changed." >&2
        echo "See the release checklist in docs/development/README.md, or use --dev to try it out." >&2
        exit 1
    fi
    echo "Note: $VERSION isn't a release; boards compare by release number" >&2
fi

mkdir -p "$OUT"
cp "$BIN" "$OUT/firmware.bin"
SIZE=$(stat -c %s "$OUT/firmware.bin")
printf '{"version": "%s", "board": "%s", "size": %d}\n' "$VERSION" "$BOARD" "$SIZE" > "$OUT/firmware.json"
echo "Bundled $VERSION for $BOARD ($SIZE bytes) in $OUT"
