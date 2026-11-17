// The 1.75" low-profile housing, pulled apart along its axis in the order it
// goes together, for the build guide's picture
include <../../hardware/boards/waveshare_esp32s3_touch_amoled_1_75/msa_low_profile_housing.scad>

gap = 22;   // how far apart the parts are pulled

// The board: the glass, and the PCB behind it
translate([0, 0, 1.5 * gap]) {
    color("#101218") translate([0, 0, -lens_t]) cylinder(d = lens_d, h = lens_t);
    color("#1f6f3a") translate([0, 0, pcb_z[0]]) cylinder(r = board_r, h = pcb_z[1] - pcb_z[0]);
}
color("#3c3c3c") body();
color("#4a4a4a") usb_plug();
// The battery, lying on its side, taped to the back
color("#2f5d8a") translate([battery_xy[0], battery_xy[1], z_back + cover_t - gap * 1.0])
    rotate(battery_rot) translate([-battery[0] / 2, -battery[1] / 2, 0]) cube(battery);
color("#4a4a4a") translate([0, 0, -gap * 2.0]) back();
