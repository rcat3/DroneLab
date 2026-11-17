// The 1.75" speaker housing from the front, for the How it works diagram
// (diagram/make_diagram.py). The glass is drawn magenta, so a screenshot can
// be put in its place.
include <../../hardware/boards/waveshare_esp32s3_touch_amoled_1_75/msa_speaker_housing.scad>
color("#2a2a2e") body();
color("#2a2a2e") chin();
color("#333338") collar();
color("#ff00ff") translate([0, 0, -lens_t]) cylinder(d = lens_d, h = lens_t + 0.01);
color("#55555c") at_pod() translate([0, 0, z_spk_back])
    linear_extrude(spk_box[2] - 0.1) rounded_rect([spk_box[1], spk_box[0]], spk_corner);
