// The 1.75" low-profile housing's travel case, for the documentation's
// pictures: closed, or with -D 'open=true', opened with the housing in it
include <../../hardware/boards/waveshare_esp32s3_touch_amoled_1_75/travel_case/low_profile_case.scad>
include <travel_case_scene.scad>

open = false;

module housing()
{
    color("#3c3c3c") body();
    color("#4a4a4a") back();
    color("#101218") translate([0, 0, -lens_t]) cylinder(d = lens_d, h = lens_t);
}

case_scene(open) housing();
