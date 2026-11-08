// Housing that screws the Waveshare RP2040-Touch-LCD-1.28 or
// RP2350-Touch-LCD-1.28 into the voice port of an MSA Millennium mask.
//
// The parts:
//  - body: one piece, with the voice port thread on its back. The board drops
//    in from the front and rests on three small pads behind its edge. Behind
//    the board, inside the thread, is a closed compartment for the battery,
//    which sits in a shallow cradle in its floor.
//    A slide switch in the side wall turns the battery on and off, held in
//    its pocket by a catch that it clicks past as it goes in, and the
//    USB-C port is reachable through a pocket in the other side.
//  - bezel: a ring over the front of the body that holds the board in by the
//    edge of its glass. It twist-locks on: three lugs inside its skirt drop
//    into slots in the body, and a turn clockwise slides them along grooves
//    that pull it down tight, until they click past a small ridge.
//  - gasket (optional): a thin ring between the body and the voice port, to
//    seal it. Print it in TPU, or cut it from 1 mm rubber or craft foam.
//  - phase_test: the thread with a scale on its front, to find thread_phase
//    (see below). Print it first.
//
// Nothing goes through the back, and there are no screws.
//
// The whole housing turns as it's screwed in, so how it ends up sitting
// depends on where the thread starts. thread_phase turns the thread on the
// body so the housing ends up level. Screw phase_test all the way into the
// mask (with the gasket, if you'll use one), hold the mask upright, read the
// number at the top of the scale, and set thread_phase to it.
//
// The board is turned a quarter turn from its usual way up, so its USB-C port
// is on the right (seen from the front), out of the way of the mask's filter
// mount below the port. Set the display's rotation to 90 degrees to match.
//
// The board's dimensions are in board.scad, and the coordinates are the
// same, except that z = 0 is the front of the bezel.
//
// Render a part to print with, for example:
//   openscad -D 'part="body"' -o body.stl msa_housing.scad

part = "preview";           // "preview", "body", "bezel", "gasket", "phase_test", "fit_test" or "layout"

include <board.scad>
include <../../masks/msa_millennium/keepout.scad>

// board = "rp2040";        // set in board.scad: "rp2040" or "rp2350"

/* [Layout] */
board_rot = 90;             // USB-C on the right
switch_angle = 145;         // the battery switch, at the upper left, clear of the pads
thread_phase = 135;         // degrees, counter-clockwise seen from the front. From phase_test

/* [Body] */
body_r = 28.5;
clearance = 0.3;            // around the board
front_round = 1.5;          // rounds the front edge of the bezel
back_chamfer = 0.8;
pad = [3.2, 3.0];           // the pads the board rests on: width, depth below the board
pad_r = 17.4;               // how far in they reach under the edge of the PCB

/* [Bezel] */
bezel_t = 1.2;              // over the edge of the glass
bezel_opening_r = active_r + 0.4;
skirt = [1.4, 3.2];         // thickness, length: the part that goes over the body
// The twist-lock. Nothing has to stretch to put it on, so it doesn't crack.
lug_angles = [60, 180, 300];    // where the lugs end up, counter-clockwise from the right seen
                                // from the front: clear of the USB-C pocket (right) and the
                                // battery plug's pocket (bottom)
lug = [6.0, 0.9, 1.2];      // width along the skirt, how far in it reaches, front to back
lock_turn = 25;             // degrees clockwise from the slots to locked
lock_play = [0.3, 0.0];     // front to back play at the start of the turn, and once locked
lock_detent = 0.2;          // how far the ridge the lugs click past reaches into the groove
lug_nub = 1.2;              // the narrow part at the leading end of each lug that clicks past
                            // the ridge. The rest of the lug's face is lower, so it clears it.
lug_clear = 0.25;           // around the lugs in the grooves, in and along
mark = [1.2, 0.5, 1.5];     // the marks that line the bezel up with the slots: width, depth, height

/* [Battery: 502030 LiPo, 5 x 20 x 30 mm, 250-310 mAh] */
battery = [30, 20, 5];      // long side, short side, thickness
battery_clear = 0.4;        // around it in its cradle
battery_gap = 1.0;          // between the top of the battery and the tallest parts on the back of
                            // the board, for a piece of 1 mm foam tape on the battery, which the
                            // board presses down
cradle_depth = 2.0;         // the pocket in the floor the battery sits in, so it can't slide
cradle_notch = [8, 6];      // width of the notch for its leads at its left end, and of the
                            // finger notches either side for lifting it out

/* [Battery switch: SS12D00-style slide switch] */
switch_body = [8.7, 3.7, 3.7];  // along the wall, front to back, out from the center
switch_lever = [1.6, 1.6];  // the lever's width along the wall, and front to back
switch_travel = 2.0;
switch_wall = 1.2;          // in front of the switch, with the slot for the lever
// The catch that keeps the switch in: the roof of its pocket is a tongue,
// free on three sides, with a hook under its free end. The switch pushes it
// up as it goes in, and it drops down behind the switch.
catch_tongue = [3.0, 0.8, 0.6];     // width, thickness, and the gap that lets it flex
catch_hook = [1.2, 0.55];   // how far along the hook's ramp is, and how far it reaches down
catch_root_r = 27.6;        // where the tongue joins the wall, from the center

/* [USB-C] */
usb_opening = [12.4, 6.6];  // the plug's overmold
usb_recess = [16.0, 1.0];   // width of the pocket in the side, and how far the port is behind its floor

/* [Gasket] */
gasket = [25.6, 28.5, 1.0]; // inner and outer radius, thickness

$fn = 96;

z_glass = -bezel_t;                             // the front of the glass, and of the body
z_pcb_back = z_glass + pcb_back_z;
z_parts_back = z_pcb_back - back_height;
z_usb = z_pcb_back - (usb_z[0] + usb_z[1]) / 2; // the USB-C port's center
usb_front_r = -usb[0][1];
usb_recess_r = usb_front_r + usb_recess[1];
// The body's back sits on the voice port's rim. It's as far forward as it can
// be with the USB-C pocket in front of it.
z_rim = min(z_usb - usb_opening[1] / 2 - 0.4 - 0.6, z_parts_back - 1.0);
z_back = z_rim - thread_length;                 // the back of the thread
z_battery = z_parts_back - battery_gap - battery[2];    // the bottom of the battery, where it sits in its cradle
z_skirt = z_glass - skirt[1];                   // where the bezel's skirt ends
skirt_ir = body_r - skirt[0];
z_switch = [z_pcb_back - 0.6 - switch_body[1], z_pcb_back - 0.6];
switch_r = body_r - switch_wall;                // the switch's outer face
switch_inner_r = switch_r - switch_body[2];     // and its inner face, where its pins are
z_pocket_top = z_switch[1] + 0.15;
catch_free_r = switch_inner_r - 0.05 - catch_hook[0];   // the free end of the catch's tongue

// The battery socket's plug goes in from the edge, so the pocket has room for
// it and its wires beside the board.
plug_box = [[battery_socket[0][0] - 6.5, battery_socket[0][1] - 0.8], [battery_socket[0][0] + 0.1, battery_socket[1][1] + 0.8]];

// Seen from the front, in the board's own coordinates
module pocket_2d()
{
    board_outline_2d(clearance);
    translate(plug_box[0]) square(box_size(plug_box));
}

module at_board()
{
    rotate([0, 0, board_rot]) children();
}

module body_shape()
{
    difference()
    {
        union()
        {
            // Behind the skirt, out to the full radius
            chamfered_prism(z_rim, z_skirt, back_chamfer, front = false) circle(r = body_r, $fn = 192);
            // and under the skirt, a little narrower
            translate([0, 0, z_skirt - 0.01]) cylinder(r = skirt_ir - 0.05, h = z_glass - z_skirt + 0.01, $fn = 192);
            // The thread, turned by thread_phase, and the floor at its end
            translate([0, 0, z_rim + 0.1]) rotate([0, 0, thread_phase]) rotate([180, 0, 0]) vpu_thread(thread_scale);
            translate([0, 0, z_back]) cylinder(r = 21.2 * thread_scale, h = z_battery + cradle_depth - z_back, $fn = 128);
        }
        lock_grooves();
        // The mark at the slot the bezel's mark lines up with to go on
        rotate([0, 0, 90 + lock_turn]) translate([body_r, 0, z_skirt]) lock_mark();
    }
}

// Millimeters along the skirt, in degrees
function skirt_deg(mm) = mm / skirt_ir * 180 / PI;
lug_half = skirt_deg(lug[0] / 2);

// The front to back room in a groove at angle a, for the lug that locks at L.
// The lug's leading (clockwise) end, its nub, ends up at L - lug_half, just
// past a narrow ridge. From there back to the slot, the groove widens from
// lock_play[1] to lock_play[0], so the turn pulls the bezel down tight.
function groove_h(a, L) =
    let(ridge_hw = skirt_deg(0.6),
        ridge_a = L - lug_half + skirt_deg(lug_nub + lug_clear) + ridge_hw,
        ramp = max(0, min(1, (a - ridge_a - ridge_hw) / lock_turn)),
        ridge = max(0, 1 - abs(a - ridge_a) / ridge_hw))
    lug[2] + lock_play[1] + ramp * (lock_play[0] - lock_play[1]) - ridge * lock_detent;

// In the body under the skirt, for each lug: a slot from the front, and a
// groove from it clockwise to where the lug locks
module lock_grooves()
{
    hw = lug_half + skirt_deg(lug_clear);
    r_in = skirt_ir - lug[1] - lug_clear;
    r_out = skirt_ir + 0.5;
    step = 1;
    for (L = lug_angles)
    {
        // The slot
        rotate([0, 0, L + lock_turn - hw]) rotate_extrude(angle = 2 * hw, $fn = 192)
            translate([r_in, z_skirt]) square([r_out - r_in, z_glass - z_skirt + 1]);
        // The groove, in thin slices
        a0 = L - hw - 0.5;
        a1 = L + lock_turn;
        n = ceil((a1 - a0) / step);
        for (i = [0 : n - 1])
            hull()
                for (a = [a0 + i * (a1 - a0) / n, a0 + (i + 1) * (a1 - a0) / n])
                    rotate([0, 0, a]) translate([r_in, -0.005, z_skirt]) cube([r_out - r_in, 0.01, groove_h(a, L)]);
    }
}

// A small V cut into the outside, pointing at the front, at x = 0
module lock_mark()
{
    translate([0, 0, -mark[2]]) rotate([0, 0, 90]) rotate([90, 0, 0])
        linear_extrude(mark[1] * 2, center = true)
            polygon([[-mark[0] / 2, -0.01], [mark[0] / 2, -0.01], [0, mark[2] + 0.01]]);
}

module body()
{
    difference()
    {
        body_shape();
        // The board's pocket, from the front down to the battery
        at_board() translate([0, 0, z_parts_back - 0.01]) linear_extrude(z_glass - z_parts_back + 1) pocket_2d();
        // The battery compartment, down to the floor, inside the thread, and
        // the cradle in the floor
        translate([0, 0, z_battery + cradle_depth]) cylinder(r = 20.9 * thread_scale, h = z_parts_back - z_battery - cradle_depth + 0.02, $fn = 128);
        translate([0, 0, z_battery]) linear_extrude(cradle_depth + 0.02) cradle_2d();
        at_board() translate([0, 0, z_rim]) linear_extrude(z_parts_back - z_rim + 0.02) board_outline_2d(clearance);
        switch_cut();
        at_board() usb_cut();
    }
    // The pads the board rests on, each with a slope below it so it prints
    // without support
    at_board() for (a = pcb_rest_angles) rotate([0, 0, a]) pcb_pad();
    switch_catch();
}

// The battery's outline in its cradle, long side across, with the notch for
// its leads at the left end and finger notches above and below
module cradle_2d()
{
    b = [battery[0], battery[1]] + [2, 2] * battery_clear;
    offset(r = 1) offset(delta = -1) square(b, center = true);
    translate([-b[0] / 2 - 2, -cradle_notch[0] / 2]) square([3, cradle_notch[0]]);
    for (s = [-1, 1]) translate([0, s * b[1] / 2]) circle(d = cradle_notch[1], $fn = 32);
}

module pcb_pad()
{
    hull()
    {
        translate([pad_r, -pad[0] / 2, z_pcb_back - pad[1]]) cube([outline_r + clearance + 1 - pad_r, pad[0], pad[1]]);
        translate([outline_r + clearance + 0.99, -pad[0] / 2, z_pcb_back - pad[1] - (outline_r + clearance + 1 - pad_r)])
            cube([0.01, pad[0], 0.01]);
    }
}

// The switch sits in a pocket in the wall, its lever out through a slot.
// It goes in from inside, before the board, and its pins point in.
module switch_cut()
{
    rotate([0, 0, switch_angle])
    {
        // The pocket, open to the inside
        translate([15, -switch_body[0] / 2 - 0.15, z_switch[0] - 0.15])
            cube([switch_r - 15, switch_body[0] + 0.3, switch_body[1] + 0.3]);
        // The slot for the lever
        translate([switch_r - 0.1, -(switch_lever[0] + switch_travel) / 2 - 0.2, (z_switch[0] + z_switch[1]) / 2 - switch_lever[1] / 2 - 0.2])
            cube([switch_wall + 1, switch_lever[0] + switch_travel + 0.4, switch_lever[1] + 0.4]);
        // Around the catch's tongue: a slot across its free end, one either
        // side, and the gap above it
        t = catch_tongue;
        r0 = catch_free_r - t[2];
        translate([r0, -t[0] / 2 - t[2], z_pocket_top - 0.01]) cube([t[2], t[0] + 2 * t[2], t[1] + t[2] + 0.01]);
        for (s = [-1, 1])
            translate([r0, s > 0 ? t[0] / 2 : -t[0] / 2 - t[2], z_pocket_top - 0.01])
                cube([catch_root_r - r0, t[2], t[1] + t[2] + 0.01]);
        translate([r0, -t[0] / 2 - t[2], z_pocket_top + t[1]])
            cube([catch_root_r - r0, t[0] + 2 * t[2], t[2]]);
    }
}

// The hook under the free end of the catch's tongue. Its ramp faces the
// center, so the switch pushes it up on the way in, and its square face
// stops the switch coming back out.
module switch_catch()
{
    rotate([0, 0, switch_angle])
        translate([0, catch_tongue[0] / 2 - 0.1, z_pocket_top + 0.01])
            rotate([90, 0, 0])
                linear_extrude(catch_tongue[0] - 0.2)
                    polygon([[catch_free_r, 0], [switch_inner_r - 0.05, 0], [switch_inner_r - 0.05, -catch_hook[1] - 0.01],
                             [switch_inner_r - 0.05 - 0.2, -catch_hook[1] - 0.01]]);
}

// In the board's coordinates: the slot for the plug, in a pocket in the side
module usb_cut()
{
    translate([0, -usb_front_r + 3, z_usb])
        rotate([90, 0, 0])
            hull()
                for (s = [-1, 1])
                    translate([s * (usb_opening[0] - usb_opening[1]) / 2, 0, 0])
                        cylinder(d = usb_opening[1], h = 20, $fn = 48);
    translate([0, -usb_recess_r, z_usb]) rotate([90, 0, 0])
        linear_extrude(20)
            offset(r = 1.5) offset(delta = -1.5)
                square([usb_recess[0], usb_opening[1] + 0.8], center = true);
}

module bezel()
{
    difference()
    {
        union()
        {
            // The ring over the glass, its front edge rounded
            intersection()
            {
                translate([0, 0, z_glass]) cylinder(r = body_r, h = bezel_t, $fn = 192);
                translate([0, 0, -front_round]) rotate_extrude($fn = 192)
                    hull()
                    {
                        square([0.01, front_round]);
                        translate([body_r - front_round, 0]) circle(r = front_round, $fn = 32);
                        translate([0, -10]) square([body_r, 10]);
                    }
            }
            // The skirt, with the lugs inside at its end
            translate([0, 0, z_skirt]) difference()
            {
                cylinder(r = body_r, h = skirt[1] + 0.01, $fn = 192);
                translate([0, 0, -1]) cylinder(r = skirt_ir, h = skirt[1] + 2, $fn = 192);
            }
            // The lugs, their faces lowered to clear the ridge except for
            // the nub at their leading (clockwise) end
            for (L = lug_angles)
            {
                rotate([0, 0, L - lug_half]) rotate_extrude(angle = 2 * lug_half, $fn = 192)
                    translate([skirt_ir - lug[1], z_skirt]) square([lug[1] + 0.01, lug[2] - lock_detent - 0.05]);
                rotate([0, 0, L - lug_half]) rotate_extrude(angle = skirt_deg(lug_nub), $fn = 192)
                    translate([skirt_ir - lug[1], z_skirt]) square([lug[1] + 0.01, lug[2]]);
            }
        }
        // The opening, with a small chamfer on its front edge
        translate([0, 0, z_glass - 1]) cylinder(r = bezel_opening_r, h = bezel_t + 2, $fn = 128);
        translate([0, 0, -0.5]) cylinder(r1 = bezel_opening_r, r2 = bezel_opening_r + 0.6, h = 0.51, $fn = 128);
        // The mark that lines up with the body's to put it on, at the top
        rotate([0, 0, 90]) translate([body_r, 0, z_skirt]) mirror([0, 0, 1]) lock_mark();
    }
}

module gasket()
{
    difference()
    {
        cylinder(r = gasket[1], h = gasket[2], $fn = 192);
        translate([0, 0, -1]) cylinder(r = gasket[0], h = gasket[2] + 2, $fn = 192);
    }
}

// The thread with a flange like the body's back, and a scale on the front.
// The number at the top, once it's screwed in, is thread_phase.
module phase_test()
{
    flange = 2.0;
    difference()
    {
        union()
        {
            vpu_thread_down();
            cylinder(r = body_r, h = flange, $fn = 192);
            // A bar across the middle to grip
            translate([-16, -2.5, 0]) cube([32, 5, flange + 4]);
        }
        translate([0, 0, -1]) cylinder(r = 15, h = flange + 2, $fn = 96);
        // Ticks every 10 degrees, longer every 30
        for (a = [0 : 10 : 350])
            rotate([0, 0, 90 + a])
                translate([body_r - (a % 30 == 0 ? 4 : 2), -0.4, flange - 0.6]) cube([5, 0.8, 1]);
    }
    // The numbers: the tick at angle a, counter-clockwise from the top, reads
    // -a, which is the thread_phase that brings it to the top. So they count
    // up clockwise, like a compass. They're bold and big enough that a slicer
    // doesn't drop their strokes as too thin for the nozzle.
    for (a = [30 : 30 : 330])
        rotate([0, 0, 90 + a]) translate([body_r - 8.5, 0, flange - 0.01]) rotate([0, 0, -90])
            linear_extrude(0.81) text(str(360 - a), size = 3.6, font = "Liberation Sans:style=Bold",
                                      halign = "center", valign = "center");
    // and an arrow in place of 0
    translate([0, body_r - 11, flange - 0.01]) linear_extrude(0.81) polygon([[-2.2, 0], [2.2, 0], [0, 5]]);
}

// The thread, pointing down from z = 0, as it is on the body
module vpu_thread_down()
{
    translate([0, 0, 0.1]) rotate([180, 0, 0]) vpu_thread(thread_scale);
}

// The front of the body with the board's pocket and pads, without the
// thread, to check the board fits before printing the whole body
module fit_test()
{
    intersection()
    {
        body();
        translate([0, 0, z_rim + 0.01]) cylinder(r = body_r + 1, h = -z_rim + 1);
    }
}

module layout()
{
    color("gray") difference()
    {
        circle(r = body_r);
        at_board() pocket_2d();
    }
    color("dimgray", 0.5) at_board() board_outline_2d();
    color("black") circle(r = bezel_opening_r);
    color("orange", 0.5) cradle_2d();
    color("red") rotate(switch_angle) translate([switch_r - switch_body[2], -switch_body[0] / 2]) square([switch_body[2], switch_body[0]]);
    color("blue") at_board() translate([-usb_recess[0] / 2, -body_r]) square([usb_recess[0], body_r - usb_recess_r]);
    color("green") at_board() for (a = pcb_rest_angles) rotate(a) translate([pad_r, -pad[0] / 2]) square([2, pad[0]]);
}

if (part == "preview")
{
    color("dimgray") body();
    color("gray") bezel();
    translate([0, 0, z_glass]) at_board() board_model();
    color("orange", 0.6) translate([0, 0, z_battery]) linear_extrude(battery[2]) square([battery[0], battery[1]], center = true);
    color("red", 0.3) translate([0, 0, z_rim]) mask_keepout();
}
else if (part == "layout") layout();
// Printed back down
else if (part == "body") translate([0, 0, -z_back]) body();
// Printed front down
else if (part == "bezel") rotate([180, 0, 0]) bezel();
else if (part == "gasket") gasket();
else if (part == "phase_test") translate([0, 0, thread_length - 0.1]) phase_test();
else if (part == "fit_test") rotate([180, 0, 0]) translate([0, 0, -z_glass]) fit_test();
