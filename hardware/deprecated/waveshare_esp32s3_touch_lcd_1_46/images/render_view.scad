// The 1.46" simple housing, assembled, for its picture, images/housing_1_46.png
include <../msa_housing.scad>
color("#3c3c3c") housing();
color("#101218") translate([0, 0, -2]) cylinder(d = lens_d, h = 2);
