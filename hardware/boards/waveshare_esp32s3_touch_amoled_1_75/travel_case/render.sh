#!/usr/bin/env bash
#
# Render the travel cases' parts to STL files for printing:
#
#   ./render.sh                 both cases
#   ./render.sh low_profile     the low-profile housing's case
#   ./render.sh speaker         the speaker housing's case
#   ./render.sh lp_case_lid     just this part
#
# The files go in the stl/ folder next to this script.

cd "$(dirname "$0")"

SCAD=low_profile_case.scad
SP=speaker_case.scad
ALL_PARTS=(lp_case_bottom lp_case_lid lp_case_clasp $SP:speaker_case_bottom $SP:speaker_case_lid $SP:speaker_case_clasp)
PART_GROUPS=(low_profile speaker)
GROUP_low_profile="lp_case_bottom lp_case_lid lp_case_clasp"
GROUP_speaker="speaker_case_bottom speaker_case_lid speaker_case_clasp"
DEFAULT=(low_profile speaker)

source ../../../common/render_parts.sh
