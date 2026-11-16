// The 1.75" speaker housing, assembled, for the documentation's pictures
include <../../hardware/boards/waveshare_esp32s3_touch_amoled_1_75/msa_speaker_housing.scad>
color("#3c3c3c") body();
color("#3c3c3c") chin();
color("#4a4a4a") back();
color("#4a4a4a") collar();
color("#4a4a4a") usb_plug();
color("#101218") translate([0, 0, -lens_t]) cylinder(d = lens_d, h = lens_t);
// The speaker, lighter than the housing, so the grille shows up against it
color("#7a7a7a") at_pod() translate([0, 0, z_spk_back])
    linear_extrude(spk_box[2] - 0.1) rounded_rect([spk_box[1], spk_box[0]], spk_corner);
