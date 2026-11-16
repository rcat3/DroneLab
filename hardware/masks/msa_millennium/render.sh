#!/usr/bin/env bash
#
# Render the voice port's test rings to STL files for printing:
#
#   ./render.sh                 the drawn thread's dial ring
#   ./render.sh tests           every test ring
#   ./render.sh mesh_dial       just these parts
#
# The files go in the stl/ folder next to this script. The mesh_dial and
# dial_rings parts have the older mesh thread in them, which is under its own
# license (see vendor/README.md).

cd "$(dirname "$0")"

SCAD=thread_test.scad
ALL_PARTS=(drawn_dial mesh_dial dial_rings fit_rings)
PART_GROUPS=(tests)
GROUP_tests="drawn_dial mesh_dial fit_rings"
DEFAULT=(drawn_dial)

source ../../common/render_parts.sh
