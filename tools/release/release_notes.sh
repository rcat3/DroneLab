#!/bin/sh
# Write a release's notes: DroneLab's banner, the Downloads heading and a
# button for each download, linked to that release's files (the firmware's to
# the web installer, which installs it from the browser), the Release notes
# heading, the changes under "New in X.Y.Z", and "Asset Files Explained",
# which says what each file is, with links to them:
#
#   tools/release/release_notes.sh vX.Y.Z changes.md > release-notes.md
#
# changes.md is just the list of what's new, one "- **Name:** what it does"
# line each. "Asset Files Explained" is notes_assets.md, here, with the tag
# put in its links; change its text there, for every release after.
#
# The headings come in two versions, and GitHub shows each viewer the one for
# their theme: the neon one in its dark themes, the _light one in its light.
#
# The buttons are drawn by tools/release/download_icons/make_icons.py, and the
# banner and headings by tools/doc_renders/gen_doc_logos.py. To add a
# platform, draw its button there, add a line here with its file, in its
# group: the companion app, the display unit's firmware, or the printed parts,
# and its file to notes_assets.md.

set -e
tag=${1:?usage: release_notes.sh vX.Y.Z changes.md}
changes=${2:?usage: release_notes.sh vX.Y.Z changes.md}
here=$(dirname "$0")
repo=https://github.com/rcat3/DroneLab
images=https://raw.githubusercontent.com/rcat3/DroneLab/master/docs/images
img=$images/downloads

link() { # image, link, alt text
    printf '<a href="%s"><img src="%s/%s.png" width="150" alt="%s"></a>\n' "$2" "$img" "$1" "$3"
}
button() { # image, the release's file, alt text
    link "$1" "$repo/releases/download/$tag/$2" "$3"
}

themed() { # image (in downloads/, with a _light version), width, alt text
    printf '<p align="center"><picture><source media="(prefers-color-scheme: dark)" srcset="%s/%s.png">' "$img" "$1"
    printf '<img src="%s/%s_light.png" width="%s" alt="%s"></picture></p>\n' "$img" "$1" "$2" "$3"
}
heading() { themed "$1" 100% "$2"; echo; }
subheading() { themed "$1" 620 "$2"; }

printf '<p align="center"><img src="%s/dronelab_banner.png" width="100%%" alt="DroneLab"></p>\n\n' "$images"
heading heading_downloads "Downloads"
subheading subheading_app "Companion App"
echo '<p align="center">'
button android DroneLab.apk "Android app, most phones"
button android-older DroneLab-armv7.apk "Android app, older 32-bit phones"
button linux-x64 DroneLab-linux-x64.tar.gz "Linux app, PC"
button linux-arm64 DroneLab-linux-arm64.tar.gz "Linux app, Raspberry Pi 4 or 5"
echo '</p>'
subheading subheading_firmware "Display Unit Firmware"
echo '<p align="center">'
link firmware-1-75 https://rcat3.github.io/DroneLab/ "Display unit firmware, Waveshare ESP32-S3 1.75 inch: the web installer"
echo '</p>'
subheading subheading_parts "3D Printed Parts"
echo '<p align="center">'
button parts-speaker DroneLab-speaker-model-stl.zip "Speaker housing, 3D printed parts"
button parts-low-profile DroneLab-low-profile-model-stl.zip "Low-profile housing, 3D printed parts"
echo '</p>'
echo
heading heading_release_notes "Release notes"
printf '\n## New in %s\n' "${tag#v}"
cat "$changes"
printf '\n\n'
sed "s/@TAG@/$tag/g" "$here/notes_assets.md"
