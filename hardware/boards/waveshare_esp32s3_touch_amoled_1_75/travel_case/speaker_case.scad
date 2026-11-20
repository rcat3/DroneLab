// A hinged travel case for the 1.75" speaker housing, with the board in it.
// The pocket is made from the housing's own design, so it follows any change
// to it: the body and the speaker's pod, the turning collar and the thread.
// The case itself is in hardware/common/travel_case.scad.
//
// Render a part to print with, for example:
//   openscad -D 'part="speaker_case_bottom"' -o speaker_case_bottom.stl speaker_case.scad

include <../msa_speaker_housing.scad>

part = "speaker_case_closed";   // "speaker_case_closed", "speaker_case_bottom",
                                // "speaker_case_lid", "speaker_case_clasp" or "clasp_test",
                                // which fits both cases.
                                // Set after the housing's design, whose own part setting it replaces

/* [Fit] */
case_clear = 0.5;           // around the housing
lid_depth = 6;              // how much of the front of the housing the lid covers
plunger_room = 1.5;         // past the plungers' ends, so the case can't press a button,
                            // even with the housing pushed against that side, or a longer test plunger

// The thread's outside, at its widest
thread_out_r = 26 * thread_scale;

case_z = [z_grip - thread_length - 0.5, z_front];      // the thread stops short of the floor, so the
                                                        // housing rests on the collar's grip, on the ledge
case_y = [-(pod_reach + case_clear), collar_r + case_clear];   // the hinge is below the pod
case_split = z_front - lid_depth;
case_x = 0;
hinge_len = 28;

// The plungers stand out of the side. Their notches go plunger_room past
// their ends: the housing can shift case_clear in the pocket, and the
// buttons only need a few tenths of a millimeter to click.
module plungers_2d()
{
    for (a = button_angles) rotate(a + board_rot) translate([body_r - 1, -plunger_d / 2]) square([plunger_proud + plunger_room + 1, plunger_d]);
}

module case_outline_2d()
{
    offset(r = case_clear) union()
    {
        outline_2d();
        circle(r = collar_r, $fn = 192);
        plungers_2d();
    }
}

// Under the pod, the pocket follows the chin's slope, so the housing is held
// there too and doesn't rock on its back. The slope is lowered so the gap
// across it, square to it, is case_clear. Lowering it moves its end nearest
// the body outwards, so it's joined with the slope as it is, which keeps the
// clearance there.
chin_drop = case_clear * sqrt(chin_shift * chin_shift + chin_h * chin_h) / chin_shift;

module case_pocket()
{
    translate([0, 0, case_z[0]]) cylinder(r = thread_out_r + case_clear, h = z_grip - case_z[0] + 0.01, $fn = 128);
    // The round part, as wide as the collar's grip all the way up: the grip is
    // the widest part of it, and has to pass the rest on its way in
    translate([0, 0, z_grip]) cylinder(r = collar_r + case_clear, h = z_front - z_grip + 0.01, $fn = 192);
    // The chin under the pod
    intersection()
    {
        union()
        {
            translate([0, 0, -chin_drop]) chin_sweep(case_clear);
            chin_sweep(case_clear);
        }
        translate([0, 0, z_back]) linear_extrude(z_pod_back - z_back + 0.01) case_outline_2d();
    }
    // The pod and the rest of the front
    translate([0, 0, z_pod_back - chin_drop]) linear_extrude(z_front - z_pod_back + chin_drop + 0.01) case_outline_2d();
}

// After the settings above, which it uses
include <../../../common/travel_case.scad>

if (part == "speaker_case_closed")
{
    case_closed();
    %color("midnightblue") { body(); chin(); }
}
else if (part == "speaker_case_bottom") case_bottom_print();
else if (part == "speaker_case_lid") case_lid_print();
else if (part == "speaker_case_clasp") case_clasp_print();
else if (part == "clasp_test") clasp_test_print();
