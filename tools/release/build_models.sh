#!/usr/bin/env bash
#
# Render the 1.75" housings and travel cases for a release, ready to print:
#
#   tools/release/build_models.sh [out_dir]
#
# Writes to out_dir (dist/ by default) one zip per model, for people who'd
# rather not install OpenSCAD, or who send the files to a print service:
#
#   DroneLab-speaker-model-stl.zip       the speaker model
#   DroneLab-low-profile-model-stl.zip   the low-profile model
#
# Each has the housing's parts, its travel case in travel_case/, the test
# prints in tests/, and a README.txt saying what each part is printed in.
# The parts are rendered with the designs' default settings.
#
# Needs OpenSCAD and zip. Run it from anywhere. The GitHub workflow
# (.github/workflows/models.yml) runs it for each release.

set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
OUT=$(realpath -m "${1:-$REPO/dist}")
BOARD_DIR=$REPO/hardware/boards/waveshare_esp32s3_touch_amoled_1_75
STL=$OUT/models/stl
VERSION=$(git -C "$REPO" describe --tags --always --dirty 2>/dev/null || echo unknown)
GUIDE=https://github.com/rcat3/DroneLab/blob/master/docs/build

mkdir -p "$STL"

# Render everything once: the housings and tests, then the travel cases
OUT="$STL" "$BOARD_DIR/render.sh" speaker low_profile tests
OUT="$STL" "$BOARD_DIR/travel_case/render.sh" speaker low_profile

# pack <zip name> <folder name> <readme> <housing parts> -- <case parts> -- <tests>
pack() {
    local zip=$1 name=$2 readme=$3
    shift 3
    local dir=$OUT/models/$name
    local sub=""
    mkdir -p "$dir/travel_case" "$dir/tests"
    for part in "$@"; do
        case $part in
            --) if [ -z "$sub" ]; then sub=travel_case/; else sub=tests/; fi ;;
            *) cp "$STL/$part.stl" "$dir/$sub$part.stl" ;;
        esac
    done
    printf '%s\n' "$readme" > "$dir/README.txt"
    (cd "$OUT/models" && zip -qr "$OUT/$zip" "$name")
    echo "Wrote $OUT/$zip"
}

LICENSE_NOTE="License: Creative Commons Attribution-NonCommercial-ShareAlike 4.0
(https://creativecommons.org/licenses/by-nc-sa/4.0/), by Rubber Cat.
You may pay a print shop, print service, makerspace or friend to print these
for your own non-commercial use. Selling prints, or devices built with them,
needs permission. See https://github.com/rcat3/DroneLab/blob/master/hardware/README.md#licenses

Not made, licensed, sponsored or endorsed by MSA. \"Compatible\" means only
that it fits the voice port. Not protective equipment."

pack DroneLab-speaker-model-stl.zip DroneLab-speaker-model "DroneLab Speaker Model: printable parts
KatCorp Drone Systems, DroneLab $VERSION

Build guide: $GUIDE/speaker-housing.md
No printer: $GUIDE/README.md#no-3d-printer

Housing (the parts come out turned the right way up to print):
  body.stl       PLA or PLA+. On one of its sides, with tree supports,
                 including the ribs inside
  chin.stl       PLA or PLA+. On its flat face, no supports
  back.stl       PLA or PLA+. As it comes, 4 or more walls
  collar.stl     PLA or PLA+. Grip down, as it comes
  washer.stl     PLA or PLA+. Two halves, flat
  gasket.stl     TPU, flat. Or cut it from 1 mm craft foam or rubber, using
                 this as a template
  plungers.stl   PLA or PLA+. Two small pins
  usb_plug.stl   Optional, TPU. A dust cover for the USB-C port

travel_case/     A hinged case to carry it in. PLA, no supports. Its hinge
                 pins are lengths of 1.75 mm filament

tests/           Quick test prints for tuning your own printer's fit:
                 lens_fit, plunger_test and pod_test. Print services can
                 skip these. To change a setting, render the parts yourself
                 from the .scad files (see the build guide)

$LICENSE_NOTE" \
    body chin back collar washer gasket plungers usb_plug \
    -- speaker_case_bottom speaker_case_lid speaker_case_clasp \
    -- lens_fit plunger_test pod_test

pack DroneLab-low-profile-model-stl.zip DroneLab-low-profile-model "DroneLab Low-Profile Model: printable parts
KatCorp Drone Systems, DroneLab $VERSION

Build guide: $GUIDE/low-profile-housing.md
No printer: $GUIDE/README.md#no-3d-printer

Housing (the parts come out turned the right way up to print):
  lp_body.stl    PLA or PLA+. Back down, with supports only for the openings
                 in the side
  lp_back.stl    PLA or PLA+. On its front, thread up, no supports, 4 or more
                 walls
  plungers.stl   PLA or PLA+. Two small pins
  usb_plug.stl   Optional, TPU. A dust cover for the USB-C port

travel_case/     A hinged case to carry it in. PLA, no supports. Its hinge
                 pins are lengths of 1.75 mm filament. Designed, not yet
                 test-printed

tests/           Quick test prints for tuning your own printer's fit and the
                 thread's angle in your mask: lp_lens_fit, lp_phase_test and
                 plunger_test. Print services can skip these. To change a
                 setting, render the parts yourself from the .scad files
                 (see the build guide)

$LICENSE_NOTE" \
    lp_body lp_back plungers usb_plug \
    -- lp_case_bottom lp_case_lid lp_case_clasp \
    -- lp_lens_fit lp_phase_test plunger_test
