// A hinged travel case, shaped around a housing. Include this file from a
// case's own .scad file, after the housing's design, so the pocket can be
// made from the housing's own shapes, and after defining what's listed below,
// which it works out its own measurements from.
//
// The housing lies in the case on its back, the display facing up, in the
// housing's own coordinates (z out of the front). The case is in two parts,
// split across the housing a little behind its front: the bottom, which
// holds most of it, and the lid. They're joined along one side by a hinge
// whose pin is a length of 1.75 mm 3D printer filament, and held shut on the
// opposite side by a clasp: a springy tab on the lid with a hook that clicks
// under a ridge on the bottom. To open it, pull the tab's end outwards.
//
// The including file defines:
//   case_pocket()      the space the housing takes up, as a 3D shape, grown by
//                      case_clear all round. The bottom of it is the lowest
//                      point of the housing, case_z[0].
//   case_outline_2d()  the pocket seen from the front: its outline at its
//                      widest, grown by case_clear
//   case_z             [the lowest point of the housing, its front]
//   case_y             [the pocket's lowest y, its highest y], seen from the
//                      front. The hinge goes on the low side, along x, and
//                      the clasp on the high side.
//   case_split         where the bottom and the lid meet, in z
//   hinge_len          how long the hinge is, along x, centered on case_x
//   case_x             where along x the hinge and the clasp are centered
//
// The parts are rendered by case_bottom_print() and case_lid_print(), turned
// the right way up to print with no supports, and case_closed() shows them
// together.

/* [Case] */
case_wall = 2.0;            // around the pocket
case_floor = 2.0;           // under the housing, and over it in the lid
case_top_gap = 0.6;         // between the front of the housing and the lid
case_corner = 3.0;          // rounds the outside, seen from the front
case_chamfer = 1.0;         // on the outer edges of the floor and the lid's top

/* [Hinge: its pin is 1.75 mm filament] */
knuckle_r = 3.4;
knuckles = 5;               // alternately on the bottom (the two ends and the middle) and the lid
knuckle_gap = 0.4;          // between neighboring knuckles
pin_hole = 2.1;             // holds 1.75 mm filament snugly. Horizontal holes print a little
                            // small; open them with a 2 mm drill if the filament won't go in

/* [Clasp: a springy tab on the lid, with a hook that clicks under a ridge on the bottom] */
clasp_w = 14;
clasp_t = 1.6;              // thin enough to flex, in PLA or PETG
clasp_len = 14;             // how far it hangs below the split. Longer flexes more easily
ridge = [0.8, 2.0];         // the ridge on the bottom: how far it stands out, and its height
hook_h = 1.6;               // the hook's height, below the ridge
clasp_grip = 2.5;           // below the hook, for a fingernail, flared outwards
clasp_pad = 2.5;            // the flat the clasp sits on, wider than the tab either side
clasp_play = 0.2;           // between the hook and the ridge, so it closes without forcing

case_bottom_z = case_z[0] - case_floor;
case_top_z = case_z[1] + case_top_gap + case_floor;
hinge_y = case_y[0] - case_wall - knuckle_r;    // the hinge's axis, in y; it's at case_split in z
wall_lo = case_y[0] - case_wall;                // the outside of the wall at the hinge
wall_hi = case_y[1] + case_wall;                // and at the clasp
ridge_z = case_split - clasp_len + clasp_grip + hook_h + clasp_play;    // the bottom of the ridge
knuckle_len = (hinge_len - (knuckles - 1) * knuckle_gap) / knuckles;

assert(ridge_z - case_bottom_z > case_chamfer + 1, "the clasp hangs below the case's floor; make it shorter");

// The outside, seen from the front: the wall around the pocket, with a flat
// where the hinge goes and another where the clasp goes, and every corner
// rounded. The flats reach in over the pocket, which is cut out afterwards.
module case_outer_2d()
{
    pad = 15;
    offset(r = case_corner) offset(r = -2 * case_corner) offset(r = case_corner)
        union()
        {
            offset(r = case_wall) case_outline_2d();
            translate([case_x - hinge_len / 2, wall_lo]) square([hinge_len, pad]);
            translate([case_x - clasp_w / 2 - clasp_pad, wall_hi - pad]) square([clasp_w + 2 * clasp_pad, pad]);
        }
}

// The whole case, closed, before it's split, with the pocket cut out
module case_shell()
{
    difference()
    {
        chamfered_prism(case_bottom_z, case_top_z, case_chamfer) case_outer_2d();
        case_pocket();
        // The pocket's front, under the lid, open straight up
        translate([0, 0, case_z[1] - 0.01]) linear_extrude(case_top_gap + 0.02) case_outline_2d();
    }
}

// Places children at each knuckle, centered on it along x, with x along the
// hinge's axis. Bottom knuckles are the even ones.
module at_knuckles(lid)
{
    for (i = [0 : knuckles - 1])
        if ((i % 2 == 1) == lid)
            translate([case_x - hinge_len / 2 + i * (knuckle_len + knuckle_gap) + knuckle_len / 2, hinge_y, case_split])
                children();
}

// A knuckle, and its web back to the wall, sloped at 45 degrees so it prints
// without supports: below the split for the bottom, above it for the lid
//
// The knuckle is tangent to the outside of the wall, so as the lid turns,
// its wall's edge, the nearest part of it to the axis, stays on the
// knuckles' surface, and nothing else comes near them.
module knuckle(lid)
{
    rotate([0, 90, 0]) translate([0, 0, -knuckle_len / 2]) linear_extrude(knuckle_len)
        // In this frame, x is -z (from the split) and y is y (from the axis)
        union()
        {
            circle(r = knuckle_r, $fn = 48);
            // The web stays on its own side of the split, or it would dip
            // into the other part's wall
            intersection()
            {
                hull()
                {
                    circle(r = knuckle_r, $fn = 48);
                    translate([lid ? -2 * knuckle_r : 0, knuckle_r - 0.01]) square([2 * knuckle_r, case_wall]);
                }
                translate([lid ? -4 * knuckle_r : 0, -2 * knuckle_r]) square([4 * knuckle_r, 4 * knuckle_r + case_wall]);
            }
        }
}

module knuckle_hole()
{
    translate([case_x - hinge_len / 2 - 1, hinge_y, case_split]) rotate([0, 90, 0])
        cylinder(d = pin_hole, h = hinge_len + 2, $fn = 24);
}

// Room for the other part's knuckles to turn in, with a gap all round
module knuckle_clear(lid)
{
    at_knuckles(!lid) rotate([0, 90, 0])
        cylinder(r = knuckle_r + knuckle_gap, h = knuckle_len + 2 * knuckle_gap, center = true, $fn = 48);
}

// The ridge on the bottom, on the flat at the clasp, with a 45 degree top so
// the hook rides over it as the lid closes
module clasp_ridge()
{
    translate([case_x - clasp_w / 2, wall_hi - 0.3, ridge_z]) rotate([90, 0, 90])
        linear_extrude(clasp_w) polygon([[0, 0], [ridge[0] + 0.3, 0], [ridge[0] + 0.3, ridge[1] - ridge[0]], [0, ridge[1]]]);
}

// The tab on the lid, standing off the bottom's wall by the ridge, with the
// hook on its inside at its lower end, and a flared grip below that
module clasp_tab()
{
    y0 = wall_hi + ridge[0] + clasp_play;       // the tab's inner face
    z_top = ridge_z - clasp_play;               // the hook's top, just under the ridge
    z_hook = z_top - hook_h;                    // the bottom of the hook
    y_hook = wall_hi + clasp_play;              // how far in the hook reaches
    translate([case_x - clasp_w / 2, 0, 0]) rotate([90, 0, 90]) linear_extrude(clasp_w)
        polygon([
            // The tab, from the lid down
            [y0, case_split + 3], [y0, z_top],
            // The hook: a flat top that catches under the ridge, and a
            // sloped underside that rides over it
            [y_hook, z_top], [y_hook, z_hook + (y0 - y_hook)], [y0, z_hook],
            // The grip, flared outwards
            [y0, z_hook - clasp_grip + 1], [y0 + 1, z_hook - clasp_grip],
            [y0 + clasp_t + 1, z_hook - clasp_grip], [y0 + clasp_t, z_hook - clasp_grip + 1],
            [y0 + clasp_t, case_split + 3]
        ]);
    // Joined to the lid's wall across the gap the ridge leaves
    translate([case_x - clasp_w / 2, wall_hi - 0.5, case_split]) cube([clasp_w, y0 - wall_hi + 0.51, 3]);
}

module case_bottom()
{
    difference()
    {
        union()
        {
            intersection()
            {
                case_shell();
                translate([0, 0, case_bottom_z - 1]) linear_extrude(case_split - case_bottom_z + 1) offset(r = 20) case_outer_2d();
            }
            at_knuckles(false) knuckle(false);
            clasp_ridge();
        }
        knuckle_hole();
        knuckle_clear(false);
    }
}

module case_lid()
{
    difference()
    {
        union()
        {
            intersection()
            {
                case_shell();
                translate([0, 0, case_split]) linear_extrude(case_top_z - case_split + 1) offset(r = 20) case_outer_2d();
            }
            at_knuckles(true) knuckle(true);
            clasp_tab();
        }
        knuckle_hole();
        knuckle_clear(true);
    }
}

module case_closed()
{
    color("dimgray") case_bottom();
    color("gray") case_lid();
}

// The bottom stands on its floor, and the lid on its top
module case_bottom_print() translate([0, 0, -case_bottom_z]) case_bottom();
module case_lid_print() rotate([180, 0, 0]) translate([0, 0, -case_top_z]) case_lid();
