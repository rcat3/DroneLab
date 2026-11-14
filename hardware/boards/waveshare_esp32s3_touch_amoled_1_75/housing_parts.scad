// What the ESP32-S3-Touch-AMOLED-1.75's housings share: the chamber behind
// the board and the back's screws, the microphones' cell, the plungers for
// the side buttons, the USB-C port's cover plug, and the marks engraved for
// the sockets and the buttons. Include it after board.scad.
//
// Its modules use the including housing's settings and measurements:
// board_rot, body_r, body_wall, battery, battery_xy, battery_rot,
// battery_clear, battery_side, mic_pos, z_back, z_face, z_button, plunger_r,
// usb_floor, edge_chamfer and front_round. A setting below can be changed by
// setting it again after the include.

/* [Microphone cell] */
mic_cell = true;
mic_cell_clear = 0.15;      // inside the cell, around the microphones' holes
mic_cell_rib = 1.0;         // the ribs that wall it off. Where it passes between MIC2's hole and
                            // a board screw, there's only just room for one this wide
mic_cell_rib_gap = 0.5;     // in front of the battery, the ribs stop this far short of it, for
                            // foam tape or plasticine to seal it
mic_sleeve = [4.4, 1.5];    // around each microphone's hole, reaching up towards the board: outer
                            // diameter, and the gap left in front of the board for a foam ring.
                            // The board is 3.5 mm in front of the plate, and each microphone is a
                            // small part on its back, about 1 mm tall

/* [Side buttons: plungers through the wall] */
plunger_d = 3.6;
plunger_clear = 0.2;        // around the plunger in its hole
plunger_flange = [5.6, 1.0];    // diameter, thickness. It's tapered on its outer side so it
                                // prints without support
plunger_tip = 3.0;          // diameter of the end that presses the button
nub_gap = 0.1;              // between the plunger and its button
plunger_proud = 1.8;        // how far it stands out of the housing
plunger_test = [1.3, 1.8, 2.3];     // how far the "plunger_test" plungers stand out, two of each

/* [USB-C cover plug] */
usb_plug_clear = 0.15;      // around the plug in its pocket
usb_tongue = [1.8, 0.05];   // how far the tongue reaches into the slot, and its clearance in it.
                            // It's a tight push fit; print the plug in TPU, or loosen this in PLA
usb_plug_notch = [6, 1.2, 1.5];     // the fingernail notch: width, depth, height

/* [Back] */
cover_t = 3.0;
cover_lip = 1.0;            // the back sits in a rebate this wide around the chamber
cover_screws = [[23, 17], [-23, 17], [23, -17], [-23, -17]];  // just outside the thread, and
                            // either side of the battery
screw_pilot = 1.7;          // M2 machine screws cut their own thread in this
screw_clear = 2.3;
screw_head = [4.2, 2.1];    // counterbore for an M2 socket head (3.8 x 2.0): diameter, depth
boss_r = 3.2;

/* [Socket marks: which socket is which, seen from the back] */
socket_marks = true;        // a speaker and a battery engraved in the back plate, beside the
                            // speaker and battery sockets, which look the same and whose labels
                            // are hidden under the plate
mark_size = 6.0;            // how tall each mark is
mark_depth = 0.6;
mark_gap = 1.0;             // between a mark and its socket's opening

/* [Button marks: which side button is which, on the outside] */
button_marks = true;        // a power symbol beside the PWR button's plunger, and a download arrow
                            // (for flashing) beside BOOT's, engraved in the side wall behind each
button_mark_size = 4.0;     // how tall each mark is
button_mark_line = 0.8;     // its lines, wide enough to print on a side wall
button_mark_depth = 0.5;
button_mark_gap = 1.2;      // between the plunger's hole and its mark

module battery_2d(grow = 0)
{
    translate(battery_xy) rotate(battery_rot)
        offset(r = 1 + grow) square([battery[0], battery[1]] + [1, 1] * (2 * battery_clear - 2), center = true);
}

module bosses_2d()
{
    for (s = cover_screws) translate(s) circle(r = boss_r, $fn = 32);
}

module chamber_2d()
{
    difference()
    {
        circle(r = body_r - body_wall, $fn = 192);
        bosses_2d();
        if (usb_access) rotate(board_rot) translate([-usb_floor[0] / 2, -body_r]) square([usb_floor[0], body_r - usb_floor[1]]);
    }
}

module rebate_2d()
{
    circle(r = body_r - body_wall + cover_lip, $fn = 192);
}

// A speaker: the magnet, the cone, and two waves coming off it. Drawn
// mark_size tall, centered, the way it reads, with lines at least 0.8 mm
// wide so they print
module speaker_mark_2d()
{
    k = mark_size / 6;
    scale(k) translate([-3.6, 0])
    {
        translate([0, -1.2]) square([1.6, 2.4]);
        polygon([[1.6, -1.2], [3.6, -3], [3.6, 3], [1.6, 1.2]]);
        for (r = [1.6, 3.2]) translate([3.6, 0]) intersection()
        {
            difference() { circle(r = r + 0.9, $fn = 48); circle(r = r, $fn = 48); }
            polygon([[0, 0], [8, -5.5], [8, 5.5]]);
        }
    }
}

// A battery: its outline, the terminal on its end, and a plus sign
module battery_mark_2d()
{
    k = mark_size / 6;
    w = 8.4; h = 4.6; t = 0.8;
    scale(k) translate([-(w + 1) / 2, 0])
    {
        translate([0, -h / 2]) difference() { square([w, h]); translate([t, t]) square([w - 2 * t, h - 2 * t]); }
        translate([w - 0.01, -1]) square([1.01, 2]);
        translate([w / 2, 0]) { square([2.6, t], center = true); square([t, 2.6], center = true); }
    }
}

// The marks, beside each socket's opening on the side towards the middle of
// the board. They're cut into the back of the plate, which is seen from the
// back, so they're mirrored to read the right way round from there, and
// upright with the pod at the bottom.
module socket_marks_2d()
{
    for (m = [[spk_conn_box, 0], [bat_conn_box, 1]])
    {
        b = m[0];
        rotate(board_rot) translate([b[1][0] + conn_grow + mark_gap + mark_size / 2, box_center(b)[1]])
            rotate(-board_rot) mirror([1, 0])
            {
                if (m[1] == 0) speaker_mark_2d(); else battery_mark_2d();
            }
    }
}

// The power symbol: a ring, open at the top, with a bar through the gap.
// Drawn button_mark_size tall, centered, upright
module power_mark_2d()
{
    s = button_mark_size;
    w = button_mark_line;
    difference()
    {
        circle(d = s, $fn = 48);
        circle(d = s - 2 * w, $fn = 48);
        polygon([[0, 0], [-s * tan(35), s], [s * tan(35), s]]);
    }
    translate([-w / 2, 0]) square([w, s / 2]);
}

// A download arrow, for BOOT, which is held to flash the board: an arrow
// pointing down onto a bar
module boot_mark_2d()
{
    s = button_mark_size;
    w = button_mark_line;
    head = [2.6, 1.5] * s / 4;      // width, height
    tip = -s / 2 + w + 0.6 * s / 4;
    translate([-s * 0.4, -s / 2]) square([s * 0.8, w]);
    polygon([[0, tip], [-head[0] / 2, tip + head[1]], [head[0] / 2, tip + head[1]]]);
    translate([-w / 2, tip + head[1] - 0.01]) square([w, s / 2 - tip - head[1] + 0.01]);
}

// The marks, engraved in the outside of the side wall behind each plunger,
// upright with the pod at the bottom, and read from outside
module button_marks()
{
    z = z_button - (plunger_d / 2 + plunger_clear) - button_mark_gap - button_mark_size / 2;
    for (i = [0, 1])
    {
        a = button_angles[i] + board_rot;
        c = cos(a);
        s = sin(a);
        // On the left side wall, seen from outside: the mark's up is along
        // the wall towards the top, its right towards the front, and its
        // depth out through the wall
        assert(c < 0, "the button marks are laid out for buttons on the left");
        multmatrix([[0, s, c, (body_r - button_mark_depth) * c],
                    [0, -c, s, (body_r - button_mark_depth) * s],
                    [1, 0, 0, z],
                    [0, 0, 0, 1]])
            linear_extrude(button_mark_depth + 1)
                if (i == 1) power_mark_2d(); else boot_mark_2d();
    }
}

// Fills the pocket around the USB-C port, with its outside following the
// body's
module usb_plug()
{
    c = usb_plug_clear;
    difference()
    {
        union()
        {
            intersection()
            {
                rotate([0, 0, board_rot]) at_bottom_edge(-usb_recess_r - c, -body_r - 2) usb_recess_2d(-c);
                rounded_prism(z_back, z_face, edge_chamfer, front_round) circle(r = body_r, $fn = 192);
            }
            rotate([0, 0, board_rot])
                at_bottom_edge(-usb_recess_r + usb_tongue[0], -usb_recess_r - c - 0.01) usb_slot_2d(-usb_tongue[1]);
        }
        rotate([0, 0, board_rot])
            translate([-usb_plug_notch[0] / 2, -body_r - 1, usb_recess_z[1] - c - usb_plug_notch[2]])
                cube([usb_plug_notch[0], 1 + usb_plug_notch[1], usb_plug_notch[2] + 1]);
    }
}

// Places children at each side button, with +z pointing out from the center
module at_buttons()
{
    rotate([0, 0, board_rot]) for (a = button_angles) rotate([0, 0, a]) translate([0, 0, z_button]) rotate([0, 90, 0]) children();
}

// A plunger, with z the distance from the center
module plunger_shape(grow = 0)
{
    f = plunger_flange + [2, 0] * grow;
    t = plunger_r[1] + f[1];                    // the flange's outer face
    translate([0, 0, plunger_r[0]]) cylinder(d = plunger_tip + 2 * grow, h = plunger_r[1] - plunger_r[0] + 0.01, $fn = 32);
    translate([0, 0, plunger_r[1]]) cylinder(d = f[0], h = f[1], $fn = 48);
    translate([0, 0, t - 0.01]) cylinder(d1 = f[0], d2 = plunger_d + 2 * grow, h = (f[0] - plunger_d) / 2 - grow + 0.01, $fn = 48);
    translate([0, 0, t]) cylinder(d = plunger_d + 2 * grow, h = plunger_r[2] - t, $fn = 32);
}

// A plunger that stands out of the housing by proud, which can differ from
// plunger_proud for test prints
module plunger(proud = plunger_proud)
{
    end = plunger_r[2] + proud - plunger_proud;
    // Printed standing on its outer end
    translate([0, 0, end]) rotate([180, 0, 0])
        intersection()
        {
            union()
            {
                plunger_shape();
                translate([0, 0, plunger_r[1]]) cylinder(d = plunger_d, h = max(end, plunger_r[2]) - plunger_r[1], $fn = 32);
            }
            cylinder(r = 10, h = end);
        }
}

// The hole for a plunger, and a recess in the wall of the display's pocket
// for its flange
module plunger_cut()
{
    g = plunger_clear;
    plunger_shape(g);
    translate([0, 0, cup_ir - 2]) cylinder(d = plunger_flange[0] + 2 * g, h = plunger_r[1] - cup_ir + 2.01, $fn = 48);
    translate([0, 0, plunger_r[2] - 1]) cylinder(d = plunger_d + 2 * g, h = 10, $fn = 32);
}

// A hole through the back for an M2 socket head screw, counterbored from
// the back face
module screw_cut()
{
    translate([0, 0, z_back - 1]) cylinder(d = screw_clear, h = cover_t + 2, $fn = 16);
    translate([0, 0, z_back - 0.01]) cylinder(d = screw_head[0], h = screw_head[1] + 0.01, $fn = 32);
}

// Inside the thread, beside the battery, into the microphones' cell, so they
// hear through the voice port
module mic_opening_2d()
{
    intersection()
    {
        circle(r = 19.5, $fn = 96);
        translate([battery_side + battery_clear, -20]) square([20, 40]);
    }
}

// The microphones' cell: the strip beside the battery, out to the chamber's
// wall, and around the microphones' holes, which are just in front of the
// battery's edge. The ribs around it are what the chamber's cut leaves: in
// front of the battery, from the back plate to just short of it, and beside
// the battery, all the way to the back.
module mic_cell_2d()
{
    r = mic_hole / 2 + mic_cell_clear;
    ys = [for (m = mic_pos) m[1]];
    hull()
    {
        for (m = mic_pos) translate(m) circle(r = r, $fn = 32);
        translate([battery_side, min(ys) - r]) square([body_r - battery_side, max(ys) - min(ys) + 2 * r]);
    }
}

module mic_cell_rib_2d()
{
    intersection()
    {
        difference()
        {
            offset(r = mic_cell_rib) mic_cell_2d();
            mic_cell_2d();
        }
        circle(r = body_r - 0.5, $fn = 192);
    }
}

// A sleeve around each microphone's hole, on the front of the back plate.
// body() bores them out
module mic_sleeves()
{
    for (m = mic_pos) translate([m[0], m[1], plate_front - 0.5])
        cylinder(d = mic_sleeve[0], h = pcb_z[0] - plate_front - mic_sleeve[1] + 0.5, $fn = 32);
}
