// The 1.46" speaker housing, assembled, for its picture, images/speaker_housing_1_46.png
include <../msa_speaker_housing.scad>
color("#3c3c3c") body();
color("#4a4a4a") back();
color("#4a4a4a") collar();
color("#101218") translate([0, 0, -2]) cylinder(d = lens_d, h = 2);
