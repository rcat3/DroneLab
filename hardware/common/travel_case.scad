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
// opposite side by a clasp: a lever that turns on a second filament pin in
// ears on the lid, with a C-shaped end that snaps round a bar on the bottom.
// To open it, pull the lever's grip outwards. Nothing in the case bends to
// open or close it but the C's upper jaw, which is a spring, free of the
// lever behind a slot, and the clasp is a separate part, printed on its side
// so its layers run round the C, and quick to reprint if it wears.
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
// The bottom and the lid meet at the split on their outer part, and the
// inner part of the bottom's wall stands up past it as a lip, into a rebate
// in the lid's wall, so the lid can't shift, and the seam is closed. The lid's
// wall outside it, its skirt, is case_wall - lip_w - lip_play thick.
//
// The parts are rendered by case_bottom_print(), case_lid_print() and
// case_clasp_print(), turned the right way up to print with no supports, and
// case_closed() shows them together. clasp_test_print() is a test print of
// clasps that snap on more and less firmly, which fit the same bar.

/* [Case] */
case_wall = 2.4;            // around the pocket, thick enough for the lip and the lid's skirt over it
case_floor = 2.0;           // under the housing, and over it in the lid
case_top_gap = 0.6;         // between the front of the housing and the lid
case_corner = 3.0;          // rounds the outside, seen from the front
case_chamfer = 1.0;         // on the outer edges of the floor and the lid's top

/* [Lip: stands up from the inside of the bottom's rim, into a rebate in the lid] */
lip_w = 1.0;
lip_h = 1.5;
lip_play = 0.2;             // between the lip and the lid, at the sides
lip_gap = 0.3;              // over the lip's top
lip_chamfer = 0.4;          // on the lip's outer top edge, to guide the lid on

/* [Hinge: its pin is 1.75 mm filament] */
knuckle_r = 3.4;
knuckles = 5;               // alternately on the bottom (the two ends and the middle) and the lid
knuckle_gap = 0.4;          // between neighboring knuckles
pin_hole = 2.1;             // holds 1.75 mm filament snugly. Horizontal holes print a little
                            // small; open them with a 2 mm drill if the filament won't go in

/* [Clasp: a lever on a filament pin in the lid, that snaps round a bar on the bottom] */
clasp_w = 14;               // the lever's width, along x
clasp_t = 3.0;              // the lever's thickness
clasp_pivot = 4.0;          // the pin's height above the split
clasp_reach = 12;           // from the pin down to the bar
barrel_r = 3.0;             // the lever's end round the pin, and the lid's ears
clasp_hole = 2.1;           // the lever turns on the pin. It prints standing, so its hole comes out round
bar_d = 4.2;                // the bar on the bottom the C snaps round
ring_t = 1.5;               // the C's wall
ring_fit = 0.15;            // inside the C, round the bar
snap = 0.45;                // how much narrower the C's mouth is than the bar: how hard it snaps.
                            // The upper jaw bends by about this much to let the bar through
jaw_slot = 0.8;             // between the C's upper jaw and the lever, so the jaw can bend
jaw_root = -10;             // where the upper jaw joins the rest of the clasp, in degrees round
                            // the C from straight out: the jaw is free from here to its tip
knee_t = 1.5;               // the lever round the outside of the slot, down to the jaw's root
clasp_test_snaps = [0.35, 0.45, 0.55];  // the clasp test's clasps, marked with one, two and three notches
clasp_grip = 4;             // below the C, flared outwards, to pull it open with
ear_w = 4;                  // the ears either side of the lever: the lid's hold the pin, the bottom's the bar
clasp_gap = 0.4;            // between the lever and the ears, and the lever's end and the lid's wall

case_bottom_z = case_z[0] - case_floor;
case_top_z = case_z[1] + case_top_gap + case_floor;
hinge_y = case_y[0] - case_wall - knuckle_r;    // the hinge's axis, in y; it's at case_split in z
wall_lo = case_y[0] - case_wall;                // the outside of the wall at the hinge
wall_hi = case_y[1] + case_wall;                // and at the clasp
knuckle_len = (hinge_len - (knuckles - 1) * knuckle_gap) / knuckles;
clasp_y = wall_hi + clasp_gap + barrel_r;       // the clasp's pin and the bar, in y
pivot_z = case_split + clasp_pivot;             // the clasp's pin, in z
bar_z = pivot_z - clasp_reach;                  // the bar, in z
ring_ri = bar_d / 2 + ring_fit;
ring_ro = ring_ri + ring_t;
function mouth_for(s) = asin((bar_d / 2 - s / 2) / ring_ri);   // half the angle the C's mouth spans
clasp_span = clasp_w + 2 * (clasp_gap + ear_w); // the ears and the lever together, along x

assert(case_wall - lip_w - lip_play >= 1, "the lid's skirt outside the lip is too thin; thicken case_wall");
assert(case_split + lip_h + lip_gap < case_z[1] + case_top_gap, "the lip is taller than the lid's wall");
assert(pivot_z + barrel_r < case_top_z, "the clasp's pin is too near the lid's top; lower clasp_pivot");
assert(pivot_z - barrel_r > case_split, "the clasp's pin is too near the split; raise clasp_pivot");
assert(bar_z - ring_ro - clasp_grip > case_bottom_z, "the clasp hangs below the case's floor; shorten clasp_reach");

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
            translate([case_x - clasp_span / 2 - 1, wall_hi - pad]) square([clasp_span + 2, pad]);
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

// The clasp's shapes are drawn across x, in (y, z), and made solid along x by
// this, from x0 for w
module along_x(x0, w)
{
    translate([x0, 0, 0]) rotate([90, 0, 90]) linear_extrude(w) children();
}

// The bar, and a web back to the wall behind it. The web spans 45 degrees
// either side of straight back, clear of the C's jaws, and its underside
// slopes at 45 degrees, so it prints without supports.
module bar_2d()
{
    reach = (clasp_y - wall_hi + 0.5) * sqrt(2);
    translate([clasp_y, bar_z])
    {
        circle(d = bar_d, $fn = 48);
        polygon([[0, 0], reach * [cos(135), sin(135)], reach * [cos(225), sin(225)]]);
    }
}

// An ear: round at the axis, and joined to the wall, with one side sloped at
// 45 degrees towards the wall so it prints without supports. up is which way
// that side faces: down for the bottom, up for the lid, which prints upside
// down.
module ear_2d(c, r, up)
{
    drop = r * sqrt(2) + (c[0] - wall_hi);
    hull()
    {
        translate(c) circle(r = r, $fn = 48);
        translate([wall_hi - 0.5, up ? c[1] - r : c[1] - drop]) square([0.5, drop + r]);
    }
}

// Places children at each of the ears, either side of the lever
module at_ears()
{
    for (s = [-1, 1])
        translate([case_x + s * (clasp_w / 2 + clasp_gap + ear_w / 2) - ear_w / 2, 0, 0]) children();
}

// The bottom's ears and the bar between them
module clasp_bar()
{
    along_x(case_x - clasp_span / 2, clasp_span) bar_2d();
    at_ears() along_x(0, ear_w) ear_2d([clasp_y, bar_z], bar_d / 2 + 1.5, false);
}

// The lid's ears, which hold the clasp's pin. Their sloped sides would rise
// past the lid's top, so they're cut off there, where the lid lies on the bed.
module clasp_ears()
{
    intersection()
    {
        at_ears() along_x(0, ear_w) ear_2d([clasp_y, pivot_z], barrel_r, true);
        translate([-500, -500, case_split]) cube([1000, 1000, case_top_z - case_split]);
    }
}

// The clasp, seen from the side, closed: a lever from its pin down to the C,
// which wraps round the bar with its mouth towards the wall, and a grip below
// the C, flared outwards. Swung in round the pin, the C's mouth meets the bar
// head on, and its jaws spread to snap over it.
//
// The C's lower half carries the lid's pull, so it's joined solidly to the
// lever and the grip. Its upper jaw is a spring: a slot jaw_slot wide
// separates it from the lever, from its tip round to jaw_root, just below
// straight out, and the lever comes down round the outside of the slot, a
// knee knee_t thick, to join the C there. Without it, the jaws were short
// and stiff, and the snap rested on a few tenths of a millimeter of the
// print's accuracy, and on its wear.
//
// s is the snap, and marks the number of small notches on the grip, which
// tell the clasp test's clasps apart.
module clasp_2d(s = snap, marks = 0)
{
    m = mouth_for(s);
    slot_ro = ring_ro + jaw_slot;
    knee = slot_ro + knee_t;
    grip_top = [clasp_y + knee, bar_z - 1.5];
    grip_end = [clasp_y + knee + 0.5, bar_z - ring_ro - clasp_grip];
    difference()
    {
        union()
        {
            translate([clasp_y, pivot_z]) circle(r = barrel_r, $fn = 48);
            translate([clasp_y, bar_z]) square([clasp_t, clasp_reach]);
            // The knee: round the outside of the slot, and down the C's outer side
            translate([clasp_y, bar_z - 1.5]) square([knee, knee + 1.5]);
            translate([clasp_y, bar_z]) circle(r = ring_ro, $fn = 64);
            polygon([
                [clasp_y + 0.5, grip_top[1]], grip_top,
                grip_end, [clasp_y + 1.5, bar_z - ring_ro - clasp_grip]
            ]);
        }
        translate([clasp_y, bar_z])
        {
            circle(r = ring_ri, $fn = 64);
            // The mouth, towards the wall
            polygon([[0, 0], 2 * ring_ro * [-cos(m), sin(m)], [-2 * ring_ro, 0], 2 * ring_ro * [-cos(m), -sin(m)]]);
            // The slot over the upper jaw
            difference()
            {
                circle(r = slot_ro, $fn = 64);
                circle(r = ring_ro, $fn = 64);
                rotate(jaw_root) translate([-2 * knee, -4 * knee]) square(4 * knee);
            }
        }
        translate([clasp_y, pivot_z]) circle(d = clasp_hole, $fn = 24);
        // The marks: notches in the grip's outer edge
        for (i = [1 : 1 : marks])
            translate(grip_top + (grip_end - grip_top) * (0.35 + 0.18 * i)) circle(d = 1.0, $fn = 16);
    }
}

module clasp(s = snap, marks = 0)
{
    along_x(case_x - clasp_w / 2, clasp_w) clasp_2d(s, marks);
}

module clasp_pin_hole()
{
    translate([case_x - clasp_span / 2 - 1, clasp_y, pivot_z]) rotate([0, 90, 0])
        cylinder(d = pin_hole, h = clasp_span + 2, $fn = 24);
}

// The lip, on the bottom, round the pocket, with its outer top edge chamfered
// in steps (a hull would fill in the outline's hollows)
module lip()
{
    steps = 4;
    translate([0, 0, case_split - 0.01]) difference()
    {
        union()
        {
            linear_extrude(lip_h - lip_chamfer + 0.01) offset(r = lip_w) case_outline_2d();
            for (i = [1 : steps])
                translate([0, 0, lip_h - lip_chamfer + (i - 1) * lip_chamfer / steps])
                    linear_extrude(lip_chamfer / steps + 0.01) offset(r = lip_w - i * lip_chamfer / steps) case_outline_2d();
        }
        translate([0, 0, -1]) linear_extrude(lip_h + 2) case_outline_2d();
    }
}

// The rebate in the lid the lip fits into
module lip_rebate()
{
    translate([0, 0, case_split - 1]) linear_extrude(1 + lip_h + lip_gap) offset(r = lip_w + lip_play) case_outline_2d();
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
            clasp_bar();
            lip();
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
            clasp_ears();
        }
        knuckle_hole();
        clasp_pin_hole();
        lip_rebate();
        knuckle_clear(true);
    }
}

module case_closed()
{
    color("dimgray") case_bottom();
    color("gray") case_lid();
    color("silver") clasp();
}

// The bottom stands on its floor, and the lid on its top
module case_bottom_print() translate([0, 0, -case_bottom_z]) case_bottom();
module case_lid_print() rotate([180, 0, 0]) translate([0, 0, -case_top_z]) case_lid();
// The clasp lies on its side, the C's profile on the bed
module case_clasp_print(s = snap, marks = 0) translate([0, 0, clasp_w / 2]) rotate([0, -90, 0]) translate([-case_x, -clasp_y, -pivot_z]) clasp(s, marks);
// The clasp test: a clasp for each of clasp_test_snaps, side by side, the
// first with one notch in its grip, the next two, and so on
module clasp_test_print()
{
    for (i = [0 : len(clasp_test_snaps) - 1])
        translate([0, i * 16, 0]) case_clasp_print(clasp_test_snaps[i], i + 1);
}
