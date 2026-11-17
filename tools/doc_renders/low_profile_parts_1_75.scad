// The 1.75" low-profile housing's parts one at a time, for the design
// README's table of parts (see speaker_parts_1_75.scad)
include <../../hardware/boards/waveshare_esp32s3_touch_amoled_1_75/msa_low_profile_housing.scad>
show = "lp_body";
if (show == "lp_body") color("#8c8c8c") body();
if (show == "lp_back") color("#8c8c8c") back();
