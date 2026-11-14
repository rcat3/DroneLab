#!/usr/bin/env bash
#
# Render the speaker housing's parts to STL files for printing:
#
#   ./render.sh                 every part of the housing
#   ./render.sh tests           the test prints, for checking a printer's fit
#   ./render.sh body back       just these parts
#
# The files go in the stl/ folder next to this script. Parts render in
# parallel, and the body and collar take the longest, around a minute.

cd "$(dirname "$0")"

SCAD=msa_speaker_housing.scad
ALL_PARTS=(body back collar washer gasket plungers spacers pod_test plunger_test)
PART_GROUPS=(speaker tests)
GROUP_speaker="body back collar washer gasket plungers spacers"
GROUP_tests="pod_test plunger_test"
DEFAULT=(speaker)

source ../../common/render_parts.sh
