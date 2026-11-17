#!/usr/bin/env bash
#
# Build the firmware for a release, and the web flasher's files:
#
#   tools/release/build_firmware.sh [out_dir]
#
# Builds the ESP32-S3-Touch-AMOLED-1.75's firmware in a new build folder
# (build-release-s3-175, so nothing left from another build gets in), and
# writes to out_dir (dist/ by default):
#
#   DroneLab-firmware-1.75.bin     the bootloader, partition table and
#                                  firmware in one file, written at 0x0 after
#                                  erasing the flash: for flashing by hand.
#                                  It clears the settings.
#   flasher/                       the web flasher (tools/release/flasher/),
#                                  with the firmware in its parts and the
#                                  manifest for ESP Web Tools. Its parts leave
#                                  the settings alone, so it can update a
#                                  board that has them.
#
# Run it from anywhere, in a terminal where ESP-IDF's export.sh has been run.
# The GitHub workflow (.github/workflows/firmware.yml) runs it for each
# release.

set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
OUT=$(realpath -m "${1:-$REPO/dist}")
BOARD=waveshare_esp32s3_touch_amoled_1_75
BUILD=$REPO/build-release-s3-175

cd "$REPO"
VERSION=$(git describe --tags --always --dirty)

if [ -d "$BUILD" ]; then
    echo "Using a fresh $BUILD: moving the old one aside"
    mv "$BUILD" "$BUILD.old.$(date +%s)"
fi
idf.py -C platforms/esp-idf -B "$BUILD" -DBOARD=$BOARD build

mkdir -p "$OUT/flasher/firmware"

# One file, for esptool or Espressif's web page. Not the OTA data, which is
# near the end of the flash and would pad the file out to 14 MB: on an erased
# board, it starts the firmware in the first app partition anyway.
MERGE_ARGS=$(grep -v ota_data "$BUILD/flash_args" | tr '\n' ' ')
(cd "$BUILD" && python -m esptool --chip esp32s3 merge_bin -o "$OUT/DroneLab-firmware-1.75.bin" $MERGE_ARGS)

# The parts, at the addresses in flash_args, for the web flasher
python - "$BUILD" "$OUT/flasher" "$VERSION" <<'PY'
import json, os, shutil, sys

build, out, version = sys.argv[1:]
parts = []
with open(os.path.join(build, "flash_args")) as f:
    for line in f:
        words = line.split()
        if len(words) == 2 and words[0].startswith("0x"):
            offset, path = int(words[0], 16), words[1]
            name = os.path.basename(path)
            shutil.copy(os.path.join(build, path), os.path.join(out, "firmware", name))
            parts.append({"path": "firmware/" + name, "offset": offset})
parts.sort(key=lambda p: p["offset"])
manifest = {
    "name": "DroneLab for the ESP32-S3-Touch-AMOLED-1.75",
    "version": version,
    # Asks whether to erase the board first, which clears its settings; left
    # unticked, an update keeps them
    "new_install_prompt_erase": True,
    "builds": [{"chipFamily": "ESP32-S3", "parts": parts}],
}
with open(os.path.join(out, "manifest.json"), "w") as f:
    json.dump(manifest, f, indent=2)
print(f"Wrote the manifest for {version}: " + ", ".join(f"{p['path']} at {p['offset']:#x}" for p in parts))
PY

cp tools/release/flasher/index.html docs/images/dronelab_banner.png "$OUT/flasher/"
sed -i "s/@VERSION@/$VERSION/g" "$OUT/flasher/index.html"

echo "Built $VERSION in $OUT"
