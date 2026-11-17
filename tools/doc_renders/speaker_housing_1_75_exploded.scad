// The 1.75" speaker housing, pulled apart along its axis in the order it goes
// together, for the build guide's picture
include <../../hardware/boards/waveshare_esp32s3_touch_amoled_1_75/msa_speaker_housing.scad>

gap = 22;   // how far apart the parts are pulled

// The board: the glass, and the PCB behind it
translate([0, 0, 1.5 * gap]) {
    color("#101218") translate([0, 0, -lens_t]) cylinder(d = lens_d, h = lens_t);
    color("#1f6f3a") translate([0, 0, pcb_z[0]]) cylinder(r = board_r, h = pcb_z[1] - pcb_z[0]);
}
color("#3c3c3c") body();
// The speaker drops into the pod from behind, and the chin closes it
color("#7a7a7a") translate([0, -18, -gap * 0.6]) at_pod() translate([0, 0, z_spk_back])
    linear_extrude(spk_box[2] - 0.1) rounded_rect([spk_box[1], spk_box[0]], spk_corner);
color("#3c3c3c") translate([0, -38, -gap * 1.1]) chin();
// The battery, standing upright, taped to the back
color("#2f5d8a") translate([battery_xy[0], battery_xy[1], z_back + cover_t - gap * 1.3])
    rotate(battery_rot) translate([-battery[0] / 2, -battery[1] / 2, 0]) cube(battery);
color("#4a4a4a") translate([0, 0, -gap * 2.4]) back();
// gasket() is drawn at z = 0, so it's moved to where it sits, between the back and the collar
color("#b05a2a") translate([0, 0, z_back - gasket[2] - gap * 2.9]) gasket();
color("#4a4a4a") translate([0, 0, -gap * 3.8]) collar();
color("#9a9a9a") translate([0, 0, -gap * 5.0]) washer();
color("#4a4a4a") usb_plug();
