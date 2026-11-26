#!/usr/bin/env bash
#
# Cut a DroneLab release, following the release checklist in
# docs/development/README.md:
#
#   tools/release/cut_release.sh draft  > changes.md      what's new, from the commits
#   tools/release/cut_release.sh X.Y.Z changes.md [options]
#
# draft prints a starting point for changes.md: a "- **Area:** what it does"
# line for each commit since the last release's tag (from "Area: what it
# does" subjects; "App version" commits are left out). Edit it by hand, it's
# only the commits' words.
#
# The release itself, for version X.Y.Z with the list in changes.md:
#
#   1. checks you're on a clean master that matches origin, the version is
#      newer than the app's, and the tag and the release don't exist yet
#   2. asks you to type the version to go ahead (--yes skips that)
#   3. sets version X.Y.Z+N in app/pubspec.yaml (N one more than now),
#      commits "App version X.Y.Z", pushes, tags vX.Y.Z and pushes the tag
#   4. builds the firmware from the tag and bundles it into the app, builds
#      the split-per-ABI APKs, and names them DroneLab.apk (arm64) and
#      DroneLab-armv7.apk
#   5. makes the notes (release_notes.sh) and creates the GitHub release with
#      the two APKs, which starts the Firmware, Models and Linux workflows
#   6. waits for them, and checks the release ends up with all seven files
#
# Options:
#   --dry-run       check everything and show the notes and the steps; change
#                   nothing, build nothing
#   --yes           don't ask for confirmation
#   --prerelease    mark the release as a pre-release. Releases are normally
#                   full ones, because the app's QR code and the docs link to
#                   releases/latest, which skips pre-releases
#   --no-wait       don't wait for the workflows after publishing
#
# If it stops part way (a build fails, say), fix the cause and run the same
# command again: a version bump or tag already made for this version at this
# commit is picked up rather than redone. Once the release exists it stops
# and says so.
#
# Needs git, gh (logged in), ESP-IDF (IDF_PATH, or in ~/esp/), flutter (on PATH
# or in ~/sdk/flutter/bin) and the release key (app/android/key.properties).

set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
GH_REPO=rcat3/DroneLab
PUBSPEC=$REPO/app/pubspec.yaml
EXPECTED_ASSETS="DroneLab.apk DroneLab-armv7.apk DroneLab-firmware-1.75.bin DroneLab-linux-x64.tar.gz DroneLab-linux-arm64.tar.gz DroneLab-speaker-model-stl.zip DroneLab-low-profile-model-stl.zip"

die() { echo "cut_release: $*" >&2; exit 1; }
say() { echo "==> $*"; }

# ---------------------------------------------------------------- draft
if [ "${1:-}" = "draft" ]; then
    cd "$REPO"
    prev=$(git describe --tags --abbrev=0 2>/dev/null) || die "no tag to start from"
    echo "# Commits since $prev: edit into the release's list" >&2
    git log --no-merges --reverse --format=%s "$prev..HEAD" \
        | grep -v '^App version ' \
        | sed -E 's/^([^:]{1,40}): /- **\1:** /; t; s/^/- **/; s/$/**/'
    exit 0
fi

# ---------------------------------------------------------------- arguments
VERSION=""; CHANGES=""; DRY=0; YES=0; PRE=0; WAIT=1
for a in "$@"; do
    case "$a" in
        --dry-run|-n) DRY=1 ;;
        --yes|-y) YES=1 ;;
        --prerelease) PRE=1 ;;
        --no-wait) WAIT=0 ;;
        -*) die "unknown option $a" ;;
        *) if [ -z "$VERSION" ]; then VERSION=$a; elif [ -z "$CHANGES" ]; then CHANGES=$a; else die "too many arguments"; fi ;;
    esac
done
[ -n "$VERSION" ] && [ -n "$CHANGES" ] || { sed -n '2,/^set -/p' "$0" | sed '$d;s/^# \{0,1\}//' >&2; exit 2; }
VERSION=${VERSION#v}
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version should be X.Y.Z, not $VERSION"
TAG=v$VERSION
TITLE="DroneLab $VERSION (test build)"
[ -f "$CHANGES" ] || die "$CHANGES not found (tools/release/cut_release.sh draft > $CHANGES)"
CHANGES=$(realpath "$CHANGES")
cd "$REPO"

# ---------------------------------------------------------------- preflight
[ -s "$CHANGES" ] || die "$CHANGES is empty"
grep -q '^- ' "$CHANGES" || die "$CHANGES has no '- **Name:** what it does' lines"
! grep -qE 'TODO|<<<<' "$CHANGES" || die "$CHANGES still has a TODO or conflict marker"
command -v gh >/dev/null || die "gh not found"
gh auth status >/dev/null 2>&1 || die "gh isn't logged in"
[ -f app/android/key.properties ] || die "app/android/key.properties (the release key) is missing"

[ "$(git rev-parse --abbrev-ref HEAD)" = master ] || die "not on master"
[ -z "$(git status --porcelain)" ] || die "the working tree has changes; commit or stash them"
git fetch -q origin master --tags
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/master)" ] || die "master doesn't match origin/master: pull or push first"

# current version, and the next version code
cur=$(sed -n 's/^version: *//p' "$PUBSPEC")
cur_name=${cur%+*}; cur_code=${cur#*+}
RESUME_BUMP=0
if [ "$cur_name" = "$VERSION" ]; then
    RESUME_BUMP=1; CODE=$cur_code     # bumped already, by an earlier run
else
    newest=$(printf '%s\n%s\n' "$cur_name" "$VERSION" | sort -V | tail -1)
    [ "$newest" = "$VERSION" ] || die "$VERSION isn't newer than the app's $cur_name"
    CODE=$((cur_code + 1))
fi

# the tag: new, or already on this commit from an earlier run
RESUME_TAG=0
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    [ "$(git rev-parse "$TAG^{commit}")" = "$(git rev-parse HEAD)" ] || die "$TAG exists, on another commit"
    RESUME_TAG=1
fi
if gh release view "$TAG" --repo "$GH_REPO" >/dev/null 2>&1; then
    die "the release $TAG already exists (fix its notes with gh api -X PATCH, see docs/development/README.md)"
fi

# ---------------------------------------------------------------- notes
WORK=$(mktemp -d)
NOTES=$WORK/release-notes.md
tools/release/release_notes.sh "$TAG" "$CHANGES" > "$NOTES"

KIND="full release"; [ "$PRE" = 1 ] && KIND="PRE-RELEASE (releases/latest, and so the app's QR link, will skip it)"
echo
echo "Release:  $TAG   \"$TITLE\""
echo "Kind:     $KIND"
echo "App:      version: $VERSION+$CODE$([ "$RESUME_BUMP" = 1 ] && echo '  (already in pubspec)')"
echo "Notes:    $NOTES"
echo "What's new:"
sed 's/^/    /' "$CHANGES"
echo
echo "Steps:"
echo "    bump pubspec, commit \"App version $VERSION\", push$([ "$RESUME_BUMP" = 1 ] && echo '   [skipped, done]')"
echo "    tag $TAG, push the tag$([ "$RESUME_TAG" = 1 ] && echo '   [skipped, done]')"
echo "    build the firmware, bundle it into the app"
echo "    build the APKs (split per ABI), name them DroneLab.apk and DroneLab-armv7.apk"
echo "    gh release create $TAG, with the notes and the two APKs"
echo "    wait for the Firmware, Models and Linux workflows; check the seven files"
echo

if [ "$DRY" = 1 ]; then
    say "dry run: nothing changed. The notes are in $NOTES"
    exit 0
fi

if [ "$YES" = 0 ]; then
    [ -t 0 ] || die "no terminal to ask on: pass --yes to go ahead"
    read -r -p "This publishes $TAG to GitHub. Type the version ($VERSION) to go ahead: " answer
    [ "$answer" = "$VERSION" ] || die "not confirmed"
fi

# ---------------------------------------------------------------- bump, tag
if [ "$RESUME_BUMP" = 0 ]; then
    say "app version $VERSION+$CODE"
    sed -i "s/^version: .*/version: $VERSION+$CODE/" "$PUBSPEC"
    git add "$PUBSPEC"
    git commit -q -m "App version $VERSION"
    git push -q origin master
fi
if [ "$RESUME_TAG" = 0 ]; then
    say "tag $TAG"
    git tag -a "$TAG" -m "$TITLE"
    git push -q origin "$TAG"
fi

# ---------------------------------------------------------------- environment
if ! { command -v idf.py >/dev/null && [ -n "${IDF_PATH:-}" ]; }; then
    root=${IDF_PATH:-}
    [ -n "$root" ] || root=$(ls -d ~/esp/esp-idf*/ 2>/dev/null | sort | tail -1 || true)
    [ -n "$root" ] && [ -f "$root/export.sh" ] || die "ESP-IDF not found: set IDF_PATH or install it in ~/esp/"
    # shellcheck disable=SC1091
    . "$root/export.sh" >/dev/null 2>&1
fi
[ -d "$HOME/sdk/flutter/bin" ] && PATH=$HOME/sdk/flutter/bin:$PATH
command -v flutter >/dev/null || die "flutter not found (on PATH or ~/sdk/flutter/bin)"

# ---------------------------------------------------------------- build
say "firmware (this takes a while)"
tools/release/build_firmware.sh "$WORK/dist"
tools/release/bundle_firmware.sh | tee "$WORK/bundle.log"
grep -q "Bundled $TAG" "$WORK/bundle.log" || die "the bundle didn't say 'Bundled $TAG'"

say "APKs"
(cd app && flutter build apk --release --split-per-abi)
APKS=$REPO/app/build/app/outputs/flutter-apk
cp "$APKS/app-arm64-v8a-release.apk" "$WORK/DroneLab.apk"
cp "$APKS/app-armeabi-v7a-release.apk" "$WORK/DroneLab-armv7.apk"

# ---------------------------------------------------------------- publish
say "publishing $TAG"
args=(--repo "$GH_REPO" --title "$TITLE" --notes-file "$NOTES")
[ "$PRE" = 1 ] && args+=(--prerelease)
gh release create "$TAG" "${args[@]}" "$WORK/DroneLab.apk" "$WORK/DroneLab-armv7.apk"

if [ "$WAIT" = 0 ]; then
    say "published. The workflows are running; check them, and the seven files, in about 10 minutes"
    exit 0
fi

# ---------------------------------------------------------------- wait, check
say "waiting for the workflows (about 10 minutes)"
deadline=$((SECONDS + 3000))
while :; do
    sleep 30
    runs=$(gh run list --repo "$GH_REPO" --limit 20 --json name,status,conclusion,headBranch \
        -q "[.[] | select(.headBranch==\"$TAG\")] | .[] | [.name,.status,.conclusion] | @tsv")
    bad=$(printf '%s\n' "$runs" | awk -F'\t' '$2=="completed" && $3!="success" && $3!="skipped" && NF' || true)
    if [ -n "$bad" ]; then
        echo "$bad" >&2
        die "a workflow failed (gh run list --repo $GH_REPO): see the checklist's step 7 for fixing one by hand"
    fi
    pending=$(printf '%s\n' "$runs" | awk -F'\t' '$2!="completed" && NF' | wc -l)
    have=$(gh release view "$TAG" --repo "$GH_REPO" --json assets -q '.assets[].name')
    missing=""
    for f in $EXPECTED_ASSETS; do grep -qx "$f" <<<"$have" || missing="$missing $f"; done
    if [ "$pending" = 0 ] && [ -z "$missing" ] && [ -n "$runs" ]; then break; fi
    if [ "$SECONDS" -gt "$deadline" ]; then die "gave up waiting; missing:${missing:- nothing, but workflows still running}"; fi
done

say "done: $TAG has all seven files"
echo "https://github.com/$GH_REPO/releases/tag/$TAG"
echo "The web installer (https://rcat3.github.io/DroneLab/) should now say $TAG."
