// Test rings for the voice port thread, side by side: the mesh thread
// (labeled MESH) and the drawn one (DRAWN), both at thread_scale.
//
// Each has a dial on its front, the same as the low-profile housing's
// lp_phase_test. Screw a ring all the way into the mask, hold the mask
// upright, and read the number at the top. Hold the mask's metal adapter
// still while unscrewing a ring, or it moves and the readings change. With
// the adapter tight, the drawn ring stopped at 90 and the mesh ring about 10
// degrees further on, at 80.
//
// Print them flat, dial down, or dial up with supports under the thread.
// ./render.sh in this folder makes the STL files.
include <voice_port.scad>

part = "dial_rings";        // "dial_rings": both; "drawn_dial" or "mesh_dial": one;
                            // "fit_rings": thread_test(), the plain rings at three scales
dial_r = 33;                // the dial's radius, a little bigger than the mask's rim
dial_t = 2.0;               // its thickness

if (part == "dial_rings")
    for (i = [0, 1])
        translate([i * (2 * dial_r + 6), 0, 0])
            phase_dial(["mesh", "drawn"][i], ["MESH", "DRAWN"][i]);
else if (part == "drawn_dial") phase_dial("drawn", "DRAWN");
else if (part == "mesh_dial") phase_dial("mesh", "MESH");
else if (part == "fit_rings") thread_test();

// The thread at thread_scale on a dial, with a bar across it to grip
module phase_dial(model, label)
{
    r = dial_r;
    difference()
    {
        union()
        {
            translate([0, 0, 0.1]) rotate([180, 0, 0]) vpu_thread(thread_scale, model);
            cylinder(r = r, h = dial_t, $fn = 192);
            translate([-16, -2.5, 0]) cube([32, 5, dial_t + 4]);
        }
        translate([0, 0, -1]) cylinder(r = 15, h = dial_t + 2, $fn = 96);
        // Ticks every 10 degrees, longer every 30
        for (a = [0 : 10 : 350])
            rotate([0, 0, 90 + a])
                translate([r - (a % 30 == 0 ? 4 : 2), -0.4, dial_t - 0.6]) cube([5, 0.8, 1]);
    }
    // The tick at angle a, counter-clockwise from the top, reads -a, which is
    // the thread_phase that brings it to the top
    for (a = [30 : 30 : 330])
        rotate([0, 0, 90 + a]) translate([r - 8.5, 0, dial_t - 0.01]) rotate([0, 0, -90])
            linear_extrude(0.81) text(str(360 - a), size = 3.6, font = "Liberation Sans:style=Bold",
                                      halign = "center", valign = "center");
    // An arrow in place of 0
    translate([0, r - 11, dial_t - 0.01]) linear_extrude(0.81) polygon([[-2.2, 0], [2.2, 0], [0, 5]]);
    // Which thread it is, below the bar
    translate([0, -19, dial_t - 0.01]) linear_extrude(0.81)
        text(label, size = 3.2, font = "Liberation Sans:style=Bold", halign = "center", valign = "center");
}
