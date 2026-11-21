// The 1.75" low-profile housing from the front, drawn like diagram_unit.scad
// (the speaker housing), for the release notes' download button
// (tools/release/download_icons/make_icons.py). The glass is magenta, so a
// screenshot can be put in its place.
include <../../hardware/boards/waveshare_esp32s3_touch_amoled_1_75/msa_low_profile_housing.scad>
color("#2a2a2e") body();
color("#ff00ff") translate([0, 0, -lens_t]) cylinder(d = lens_d, h = lens_t + 0.01);
