#!/usr/bin/env bash
#
# Render the phone bracer's parts to STL files for printing:
#
#   ./render.sh                 every part
#   ./render.sh fit_test        just the fit test, to check the bracer on the arm first
#
# Set your arm's measurements and phone in phone_bracer.scad first. The files
# go in the stl/ folder next to this script.

cd "$(dirname "$0")"

SCAD=phone_bracer.scad
ALL_PARTS=(bracer mount plug cradle ptt_lid fit_test)
DEFAULT=(bracer mount plug cradle ptt_lid)

source ../../common/render_parts.sh
