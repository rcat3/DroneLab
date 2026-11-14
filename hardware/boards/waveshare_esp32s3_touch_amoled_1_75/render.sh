#!/usr/bin/env bash
#
# Render the housings' parts to STL files for printing:
#
#   ./render.sh                 both housings
#   ./render.sh speaker         the speaker housing (msa_speaker_housing.scad)
#   ./render.sh low_profile     the low-profile housing (msa_low_profile_housing.scad)
#   ./render.sh tests           the test prints, for checking a printer's fit
#   ./render.sh body chin       just these parts
#
# The files go in the stl/ folder next to this script. Parts render in
# parallel, and the bodies and the collar take the longest, around a minute.
# The low-profile housing's parts are named lp_body and so on, to keep them
# apart from the speaker housing's.

cd "$(dirname "$0")"

SCAD=msa_speaker_housing.scad
LP=msa_low_profile_housing.scad
ALL_PARTS=(body chin back collar washer gasket plungers usb_plug pod_test plunger_test lens_fit
           $LP:lp_body $LP:lp_back $LP:lp_phase_test $LP:lp_lens_fit)
PART_GROUPS=(speaker low_profile tests)
GROUP_speaker="body chin back collar washer gasket plungers usb_plug"
GROUP_low_profile="lp_body lp_back plungers usb_plug"
GROUP_tests="pod_test plunger_test lens_fit lp_phase_test lp_lens_fit"
DEFAULT=(speaker low_profile)

source ../../common/render_parts.sh
