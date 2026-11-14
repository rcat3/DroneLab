// A hinged travel case for the 1.75" low-profile housing, with the board in
// it. The pocket is made from the housing's own design, so it follows any
// change to it. The case itself is in hardware/common/travel_case.scad.
//
// Render a part to print with, for example:
//   openscad -D 'part="lp_case_bottom"' -o lp_case_bottom.stl low_profile_case.scad

include <../msa_low_profile_housing.scad>

part = "lp_case_closed";    // "lp_case_closed", "lp_case_bottom" or "lp_case_lid". Set after the
                            // housing's design, whose own part setting it replaces

/* [Fit] */
case_clear = 0.5;           // around the housing
lid_depth = 6;              // how much of the front of the housing the lid covers

// The thread's outside, at its widest
thread_out_r = 26 * thread_scale;

case_z = [z_back - thread_length - 0.5, z_front];      // the thread stops short of the floor, so the
                                                        // housing rests on its back, on the ledge
case_y = [-(body_r + case_clear), body_r + case_clear];
case_split = z_front - lid_depth;
case_x = 0;
hinge_len = 30;

// The plungers stand out of the side
module plungers_2d()
{
    for (a = button_angles) rotate(a + board_rot) translate([body_r - 1, -plunger_d / 2]) square([plunger_proud + 1, plunger_d]);
}

module case_outline_2d()
{
    offset(r = case_clear) union()
    {
        circle(r = body_r, $fn = 192);
        plungers_2d();
    }
}

module case_pocket()
{
    translate([0, 0, case_z[0]]) cylinder(r = thread_out_r + case_clear, h = z_back - case_z[0] + 0.01, $fn = 128);
    translate([0, 0, z_back]) linear_extrude(z_front - z_back + 0.01) case_outline_2d();
}

// After the settings above, which it uses
include <../../../common/travel_case.scad>

if (part == "lp_case_closed")
{
    case_closed();
    %color("midnightblue") body();
}
else if (part == "lp_case_bottom") case_bottom_print();
else if (part == "lp_case_lid") case_lid_print();
