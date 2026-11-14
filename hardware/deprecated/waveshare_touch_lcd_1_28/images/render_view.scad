// The 1.28" housing, assembled, for its picture, images/housing_1_28.png
include <../msa_housing.scad>
color("#3c3c3c") body();
color("#4a4a4a") bezel();
color("#101218") translate([0, 0, z_glass - glass_t]) cylinder(r = glass_r, h = glass_t, $fn = 128);
