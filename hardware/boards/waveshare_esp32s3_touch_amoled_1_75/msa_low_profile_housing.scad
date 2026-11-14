// Low-profile housing for the Waveshare ESP32-S3-Touch-AMOLED-1.75: the
// display in front, a flat battery in a shallow chamber behind it, and the
// voice port thread fixed to the back. There's no speaker. It screws into the
// voice port of an MSA Millennium mask, and stands about 22.5 mm out of it.
//
// The parts:
//  - body: the display cup, with the chamber behind it, hollow at the back.
//    Shallow ridges around its side give a grip for screwing it in.
//  - back: closes the chamber, and carries the voice port thread. The battery
//    is taped to its front, lying on its side, in an outline engraved there,
//    and the voice port is open
//    beside it, behind the microphones. Four M2 x 8 socket head screws hold
//    it on, in a lopsided pattern, so it only goes on one way.
//
// The battery is small enough to fit between the board's battery socket,
// below it, its pin header, above it, and the microphones, to its right. The
// battery's plug goes into the socket from behind, so with the battery clear
// of it, the battery can sit right behind the board's back plate, with no
// room left in front of it for the plug, and the housing is that much
// thinner.
//
// There's no speaker, so the microphones don't need the speaker housing's
// cell, walled off from the chamber. The sleeves around their holes are kept,
// with foam rings sealing them against the board, so they hear the chamber,
// which is open to the voice port, and not the gap behind the board, which
// is open to the outside through the USB-C and micro SD openings.
//  - usb_plug: fills the pocket around the USB-C port when it's not in use,
//    flush with the outside, as on the speaker housing.
//  - plungers: two pins that press the board's side buttons through the
//    wall on the left, as on the speaker housing.
//
// The whole housing turns as it's screwed in, so how it ends up sitting
// depends on where the thread starts, which is the same on every Millennium.
// thread_phase turns the thread on the back so the housing ends up level. It
// comes from the 1.28" housing (now in hardware/deprecated), which has the
// same thread, fixed to its back in the same way. To check it on a mask,
// screw phase_test all the way in, hold the mask upright, and read the
// number at the top of its scale.
//
// The board is turned a quarter turn from its usual way up, as in the
// speaker housing, so its USB-C port faces right, out through the side, and
// its buttons and micro SD slot are on the left. The firmware turns the
// picture to match.
//
// The chamber, the microphones' sleeves, the plungers, the USB-C plug and the
// marks are shared with the speaker housing, in housing_parts.scad. The
// board's dimensions are in board.scad, and the coordinates are the same:
// the front of the glass is at z = 0 and the body extends towards -z. The
// preview shows the parts of the mask around the voice port in red
// (hardware/masks/msa_millennium/keepout.scad), to check nothing hangs into
// them.
//
// Render a part to print with, for example:
//   openscad -D 'part="lp_body"' -o lp_body.stl msa_low_profile_housing.scad

part = "preview";           // "preview", "lp_body", "lp_back", "plungers", "usb_plug", "plunger_test",
                            // "lp_phase_test", "lp_lens_fit" or "layout". The lp_ names keep the
                            // STL files apart from the speaker housing's, in the same folder

include <board.scad>
include <../../masks/msa_millennium/keepout.scad>
include <housing_parts.scad>

/* [Battery: 603040 LiPo, 6 x 30 x 40 mm, about 700-850 mAh] */
battery = [41, 30.5, 6.3];  // taped to the back, lying on its side. A little bigger than the
                            // usual size, for the protection board on its end and the swelling
                            // of a cell that's been charged
battery_xy = [-5.5, 0.6];   // where its center is, seen from the front: left of the
                            // microphones, and just above the board's battery socket
battery_rot = 0;            // lying on its side
battery_clear = 0.5;
battery_gap = 0.8;          // between the battery and the back plate, for the battery's swelling and
                            // the foam tape that holds it
plug_clear = 0.5;           // between the battery and the board's battery socket, where the plug goes
battery_outline = [0.8, 0.4];   // an outline engraved on the front of the back, showing where to tape
                                // the battery: line width, depth

/* [Layout] */
board_rot = 90;             // USB-C to the right, buttons and micro SD to the left
thread_phase = 123;         // degrees, counter-clockwise seen from the front. From the 1.28"
                            // housing, screwed into a mask
body_r = 34;                // the same as the speaker housing's, big enough for the battery's corners
body_wall = 3.0;
edge_chamfer = 1.0;         // back edge of the body
front_round = 4.0;          // rounds the front edge of the body
bezel_step = 1.0;           // the ring around the display stands this far proud of the face
bezel_chamfer = 0.5;        // on the outside of the ring
usb_floor = [20, 26.5];     // width, and distance from the center: the chamber stops here under the
                            // pocket around the USB-C port, so the pocket has a solid floor

/* [Grip: ridges around the side, behind the openings] */
grip_count = 60;
grip_r = 1.0;               // each groove between the ridges is a cylinder this big
grip_depth = 0.6;           // how far the grooves go into the side
grip_top = 1.5;             // the grooves stop this far behind the back plate, clear of the
                            // pocket around the USB-C port

/* [Back] */
// Clear of the battery and the board's battery socket, and in a lopsided
// pattern, so the back only goes on one way round: the right way for the
// thread, and for the opening behind the microphones. Each meets the
// chamber's wall.
cover_screws = [[-20, 20.5], [16, 23.7], [-20, -20.5], [22, -18.3]];

$fn = 96;

z_front = cup_top;                                          // the ring around the display
z_face = z_front - bezel_step;                              // the rest of the front
chamber_depth = battery[2] + battery_gap;
chamber_top = plate_back;
z_back = chamber_top - chamber_depth - cover_t;             // where the voice port's rim ends up
z_button = (button_z[0] + button_z[1]) / 2;
plunger_r = [button_reach_r + nub_gap, cup_ir + 0.3, body_r + plunger_proud];  // tip, flange, outer end

// The board's microphones, seen from the front, in the housing
mic_pos = [for (m = mic_xy) [m[0] * cos(board_rot) - m[1] * sin(board_rot), m[0] * sin(board_rot) + m[1] * cos(board_rot)]];
// The battery's side towards the microphones
battery_side = battery_xy[0] + battery[0] / 2;
// The board's battery socket, in the housing: its top edge, seen from the
// front
bat_conn_top = bat_conn_box[1][0];

assert(battery_rot == 0, "the battery is laid out lying on its side, clear of the socket and the microphones");
assert(board_rot == 90, "the battery's place is worked out for the board turned a quarter turn");
assert(battery_xy[1] - battery[1] / 2 - battery_clear >= bat_conn_top + plug_clear,
       "the battery has to clear the board's battery socket, where the plug goes in from behind");
assert(battery_side + battery_clear <= min([for (m = mic_pos) m[0]]) - mic_hole / 2,
       "the battery has to clear the microphones' holes");
for (s = cover_screws)
    assert(norm(s) + boss_r > body_r - body_wall, "each screw's boss has to meet the chamber's wall");

module body()
{
    // The sleeves stand in the display's pocket, so they go on after it's cut
    difference()
    {
        union()
        {
            body_shell();
            mic_sleeves();
        }
        for (m = mic_pos) translate([m[0], m[1], plate_back - 1]) cylinder(d = mic_hole, h = 10, $fn = 24);
    }
}

module body_shell()
{
    difference()
    {
        union()
        {
            rounded_prism(z_back, z_face, edge_chamfer, front_round) circle(r = body_r, $fn = 192);
            // The ring around the display
            translate([0, 0, z_face - 0.01])
            {
                cylinder(r = cup_or, h = bezel_step - bezel_chamfer + 0.01, $fn = 128);
                translate([0, 0, bezel_step - bezel_chamfer])
                    cylinder(r1 = cup_or, r2 = cup_or - bezel_chamfer, h = bezel_chamfer + 0.01, $fn = 128);
            }
        }
        // The display's pocket, with a small chamfer on its front edge
        translate([0, 0, plate_front]) cylinder(r = cup_ir, h = 20, $fn = 128);
        translate([0, 0, z_front - 0.6]) cylinder(r1 = cup_ir, r2 = cup_ir + 0.6, h = 0.61, $fn = 128);
        rotate([0, 0, board_rot])
        {
            plate_holes();
            wall_openings();
        }
        at_buttons() plunger_cut();
        // The chamber, and the rebate the back sits in
        translate([0, 0, z_back - 1]) linear_extrude(chamber_top - z_back + 1) chamber_2d();
        translate([0, 0, z_back - 1]) linear_extrude(cover_t + 1) rebate_2d();
        for (s = cover_screws)
            translate([s[0], s[1], z_back - 1]) cylinder(d = screw_pilot, h = cover_t + 9, $fn = 16);
        if (socket_marks)
            translate([0, 0, plate_back - 1]) linear_extrude(mark_depth + 1) socket_marks_2d();
        if (button_marks) button_marks();
        grip();
    }
}

// Grooves around the side, from the back to just behind the back plate. Their
// front ends are rounded off, and at the back they run out through the
// chamfer.
module grip()
{
    top = plate_back - grip_top;
    for (i = [0 : grip_count - 1])
        rotate([0, 0, (i + 0.5) * 360 / grip_count]) translate([body_r + grip_r - grip_depth, 0, 0])
        {
            translate([0, 0, z_back - 1]) cylinder(r = grip_r, h = top - grip_r - z_back + 1, $fn = 16);
            translate([0, 0, top - grip_r]) sphere(r = grip_r, $fn = 16);
        }
}

// The voice port thread, turned by thread_phase, pointing back from the back
// face of the back. It overlaps the back slightly so the two fuse.
module thread()
{
    translate([0, 0, z_back + 0.1]) rotate([0, 0, thread_phase]) rotate([180, 0, 0]) vpu_thread(thread_scale);
}

// The back, with its back face at z_back, and the thread behind it
module back()
{
    difference()
    {
        union()
        {
            translate([0, 0, z_back]) linear_extrude(cover_t) offset(delta = -0.2) rebate_2d();
            thread();
        }
        translate([0, 0, z_back - thread_length - 1]) linear_extrude(cover_t + thread_length + 2) mic_opening_2d();
        for (s = cover_screws) translate(s) screw_cut();
        // Where the battery goes
        translate([0, 0, z_back + cover_t - battery_outline[1]]) linear_extrude(battery_outline[1] + 1) difference()
        {
            battery_2d(-battery_clear);
            battery_2d(-battery_clear - battery_outline[0]);
        }
    }
}

// The thread with a flange like the back's, and a scale on the front. Screwed
// all the way into a mask held upright, the number at the top is
// thread_phase. The same as the 1.28" housing's phase_test, on a flange the
// size of this housing.
module phase_test()
{
    flange = 2.0;
    r = body_r;
    difference()
    {
        union()
        {
            translate([0, 0, 0.1]) rotate([180, 0, 0]) vpu_thread(thread_scale);
            cylinder(r = r, h = flange, $fn = 192);
            // A bar across the middle to grip
            translate([-16, -2.5, 0]) cube([32, 5, flange + 4]);
        }
        translate([0, 0, -1]) cylinder(r = 15, h = flange + 2, $fn = 96);
        // Ticks every 10 degrees, longer every 30
        for (a = [0 : 10 : 350])
            rotate([0, 0, 90 + a])
                translate([r - (a % 30 == 0 ? 4 : 2), -0.4, flange - 0.6]) cube([5, 0.8, 1]);
    }
    // The tick at angle a, counter-clockwise from the top, reads -a, which is
    // the thread_phase that brings it to the top
    for (a = [30 : 30 : 330])
        rotate([0, 0, 90 + a]) translate([r - 8.5, 0, flange - 0.01]) rotate([0, 0, -90])
            linear_extrude(0.81) text(str(360 - a), size = 3.6, font = "Liberation Sans:style=Bold",
                                      halign = "center", valign = "center");
    // and an arrow in place of 0
    translate([0, r - 11, flange - 0.01]) linear_extrude(0.81) polygon([[-2.2, 0], [2.2, 0], [0, 5]]);
}

// The front 3 mm of the body around the display, to check the glass fits
// before printing the lot
module lens_fit()
{
    intersection()
    {
        body();
        translate([0, 0, z_front - 3]) cylinder(r = cup_or + 4, h = 4);
    }
}

// The layout seen from the front, with the battery, the back's screws, and
// the board's sockets, microphones, buttons, USB-C port and micro SD slot
// marked
module layout()
{
    color("gray") difference()
    {
        circle(r = body_r, $fn = 192);
        chamber_2d();
    }
    color("orange", 0.5) battery_2d();
    color("cyan") mic_opening_2d();
    rotate(board_rot)
    {
        color("red") for (a = button_angles) rotate(a) translate([cup_ir, -1.5]) square([body_r - cup_ir, 3]);
        color("blue") translate([(sd_x[0] + sd_x[1]) / 2 - sd_opening[0] / 2, cup_ir]) square([sd_opening[0], body_r - cup_ir]);
        color("blue") translate([-usb_opening[0] / 2, -body_r]) square([usb_opening[0], body_r - cup_ir]);
        color("magenta") for (m = mic_xy) translate(m) circle(d = 2);
        color("green") for (b = [spk_conn_box, bat_conn_box]) translate(b[0]) square(box_size(b));
        color("yellow") translate(header_box[0]) square(box_size(header_box));
    }
    color("purple") for (c = cover_screws) translate(c) circle(d = screw_head[0]);
    color("dimgray", 0.4) circle(r = cup_ir);
}

if (part == "preview")
{
    color("dimgray") body();
    color("gray") back();
    color("gray") usb_plug();
    color("midnightblue") translate([0, 0, -lens_t]) cylinder(d = lens_d, h = lens_t);
    color("red", 0.4) translate([0, 0, z_back]) mask_keepout();
}
else if (part == "layout") layout();
// Printed back down
else if (part == "lp_body") translate([0, 0, -z_back]) body();
// Printed on its front, with the thread pointing up
else if (part == "lp_back") rotate([180, 0, 0]) translate([0, 0, -z_back - cover_t]) back();
// Printed standing on its flat bottom face
else if (part == "usb_plug") translate([0, 0, -usb_recess_z[0] - usb_plug_clear]) usb_plug();
else if (part == "plungers") for (i = [0, 1]) translate([i * 8, 0, 0]) plunger();
else if (part == "plunger_test")
    for (i = [0 : len(plunger_test) - 1], j = [0, 1]) translate([i * 8, j * 8, 0]) plunger(plunger_test[i]);
else if (part == "lp_phase_test") translate([0, 0, thread_length - 0.1]) phase_test();
else if (part == "lp_lens_fit") rotate([180, 0, 0]) translate([0, 0, -z_front]) lens_fit();
