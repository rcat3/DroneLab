#!/usr/bin/env bash
#
# Render the housing's parts to STL files for printing:
#
#   ./render.sh                 the housing (msa_housing.scad)
#   ./render.sh tests           the test prints, for checking a printer's fit
#   ./render.sh simple          the same
#   ./render.sh lens_fit        just these parts
#
# The files go in the stl/ folder next to this script.

cd "$(dirname "$0")"

SCAD=msa_housing.scad
ALL_PARTS=(housing fit_test lens_fit thread_test)
PART_GROUPS=(simple tests)
GROUP_simple="housing"
GROUP_tests="fit_test lens_fit thread_test"
DEFAULT=(simple)

source ../../common/render_parts.sh
