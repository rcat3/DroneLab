// All-in-one housing for the Waveshare ESP32-S3-Touch-AMOLED-1.75: the
// display in the middle, one speaker in a pod below it, and a chamber behind
// for the battery. It screws into the voice port of an MSA Millennium mask.
//
// The board has its own amplifier, speaker socket and microphones, so there
// are no other boards to wire in: the speaker and the battery plug straight
// into the board.
//
// The parts:
//  - body: the display cup and the speaker pod, in one piece, hollow at the
//    back. The pod is shallow, so it stays in front of the mask's filter
//    mount, which is right below the voice port. The speaker is a sealed box
//    module. It goes into its pocket from the back of the pod, and the
//    adhesive frame on its front sticks it to the grille.
//  - chin: closes the back of the pod, and slopes from it back to the body,
//    over the filter mount. Four M2 x 8 socket head screws hold it on.
//  - back: closes the chamber. The battery is taped to it, standing upright,
//    and the voice port is open beside it, behind the microphones.
//  - collar, washer and gasket: the voice port thread, which turns freely on
//    the back, so the housing can be held level while only the collar is
//    screwed in. They're in hardware/masks/msa_millennium/turning_collar.scad.
//  - usb_plug: fills the pocket around the USB-C port when it's not in use,
//    flush with the outside. A tongue on its back pushes into the slot for
//    the plug, and a notch at its top edge is for a fingernail to pull it
//    out.
//  - plungers: two pins that press the board's side buttons through the
//    thick wall on the left. Each goes in from inside the display's pocket
//    before the board, and a flange on its inner end keeps it from falling
//    out.
//
// The back is held on with four M2 x 8 socket head screws, which cut their
// own threads in the body.
//
// The microphones have a cell of their own: the strip of the chamber beside
// the battery, walled off from the rest of it, with the voice port open into
// it through the back. Ribs on the back plate wall it off, and the battery's
// side closes it. In front of the battery the ribs stop short of it, and a
// strip of foam tape or plasticine on them seals it against the battery. The
// rest of the chamber, with the sockets and the speaker's wire, is on the
// other side. Behind the plate, the board sits on its standoffs, so a sleeve
// around each microphone's hole reaches up towards the board, and a foam ring
// on it seals it there, so the microphones only hear the cell.
//
// The board is turned a quarter turn from its usual way up, so its USB-C port
// faces right, out through the side of the housing, instead of into the pod.
// Its buttons and micro SD slot are on the left, and its pin header at the
// top. The firmware turns the picture to match.
//
// The board's dimensions are in board.scad, and the coordinates are the
// same: the front of the glass is at z = 0 and the body extends towards -z.
// The preview shows the parts of the mask around the voice port in red
// (hardware/masks/msa_millennium/keepout.scad), to check nothing hangs into
// them.
//
// Render a part to print with, for example:
//   openscad -D 'part="body"' -o body.stl msa_speaker_housing.scad

part = "preview";           // "preview", "body", "chin", "back", "collar", "washer", "gasket", "plungers",
                            // "usb_plug", "plunger_test", "pod_test", "lens_fit" or "layout"

include <board.scad>
include <../../masks/msa_millennium/turning_collar.scad>
include <../../masks/msa_millennium/keepout.scad>
include <housing_parts.scad>

/* [Speaker: DWEII 3525 box module, 4 ohm 3 W] */
spk_box = [35, 25, 6.5];    // long side, short side, thickness with the adhesive frame
spk_corner = 2.0;           // the box's corners, seen from the front
spk_cone = [30, 20.5];      // the oval cone, inside the adhesive frame on the front
spk_clear = 0.3;
spk_back_gap = 2.0;         // behind the speaker, for its wire to run to the chamber
pocket_floor = 1.6;         // where the pocket's inner end reaches over the chamber's edge, the wall
                            // between them. It leaves a smaller gap behind that end of the speaker
spk_wire_notch = [5, 2];    // in the middle of each short side of the pocket, for the wire where
                            // it comes out of the box: width, depth
wire_pass = [7, 4];         // the opening from the pocket into the chamber, for the speaker's plug
                            // (about 5 mm wide) to go through, and no more, as it's sealed with
                            // plasticine around the wire: width, and how far behind the chamber's
                            // top it reaches out into the body's wall, leaving 1 mm of it

/* [Battery: 103450 LiPo, 10 x 34 x 50 mm, 2000 mAh] */
battery = [50.5, 34, 9.9];  // taped to the back
battery_xy = [0, 0];        // where its center is, seen from the front
battery_rot = 90;           // standing upright, so the voice port is open beside it, behind the
                            // microphones. Only 90 is supported
battery_clear = 0.5;
battery_gap = 4.0;          // in front of the battery, for the plugs in the board's speaker and
                            // battery sockets, which go in from behind, and their wires

/* [Layout] */
board_rot = 90;             // USB-C to the right, buttons and micro SD to the left
pod_angle = -90;            // where the pod sits around the display: -90 is straight down
pod_inset = 1.2;            // between the display's cup and the speaker pocket
pod_wall = 4.0;             // around the speaker pocket, thick enough at the sides for the chin's screws
pod_corner = 7.5;           // rounds the pod's corners, seen from the front
waist_r = 40;               // the curves joining the pod to the body
body_r = 34;                // the body around the display, big enough for the battery's corners
body_wall = 3.0;
edge_chamfer = 1.0;         // back edge of the body
slab_chamfer = 0.5;         // back edge of the pod, where it meets the chin
front_round = 4.0;          // rounds the front edge of the body
bezel_step = 1.0;           // the ring around the display stands this far proud of the face
bezel_chamfer = 0.5;        // on the outside of the ring
chin_foot = 1.5;            // the chin's sloped underside meets the back this far below the body
usb_floor = [20, 26.5];     // width, and distance from the center: the chamber stops here under the
                            // pocket around the USB-C port, so the pocket has a solid floor

/* [Grille] */
grille_t = 1.6;
cone_gap = 0.8;             // a recess in the back of the grille, in front of the cone. The
                            // speaker's adhesive frame sticks to the flat ring around it
grille_slot = 1.6;          // the slots run across the short side of the speaker
grille_bar = 1.2;

/* [Chin] */
chin_screw_grip = 3.5;      // how much of the chin each of its screws clamps, under the head

/* [Collar: the rest of its settings are in turning_collar.scad] */
collar_r = 35;              // a little bigger than the body, so it can be turned from the sides

$fn = 96;

z_front = cup_top;                                          // the ring around the display
z_face = z_front - bezel_step;                              // the rest of the front
z_land = z_face - grille_t - cone_gap;                      // the front of the speaker
z_spk_back = z_land - spk_box[2];
z_pod_back = z_spk_back - spk_back_gap;                     // where the chin meets the pod
chamber_depth = battery[2] + battery_gap;
chamber_top = plate_back;
z_back = chamber_top - chamber_depth - cover_t;
z_grip = z_back - gasket_t - collar_t;                      // the back of the collar's grip, and
                                                            // the front of the voice port's rim
z_button = (button_z[0] + button_z[1]) / 2;
plunger_r = [button_reach_r + nub_gap, cup_ir + 0.3, body_r + plunger_proud];  // tip, flange, outer end

pocket = [spk_box[0], spk_box[1]] + [2, 2] * spk_clear;
pod_dist = cup_or + pod_inset + pocket[1] / 2;
pod_size = pocket + [2, 2] * pod_wall;
pod_reach = pod_dist + pod_size[1] / 2;                     // the pod's outer end, from the center
chin_h = z_pod_back - z_back;
chin_shift = pod_reach - body_r - chin_foot;                // how far the underside slopes in
// The chin's screws, in the pod's coordinates: two near the pod's outer end
// and two near the body, in the pod's walls either side of the pocket
chin_screws = [for (x = [6, -7.5], s = [-1, 1]) [x, s * (pocket[0] / 2 + pod_wall / 2)]];


// Places children at the pod, turned so +x points away from the display and
// the speaker's long side runs along y
module at_pod()
{
    rotate([0, 0, pod_angle]) translate([pod_dist, 0, 0]) children();
}

module pod_2d(grow = 0)
{
    rounded_rect([pod_size[1], pod_size[0]] + [2, 2] * grow, pod_corner + grow);
}

// The outline of the body seen from the front: the display and the pod, with
// curves of radius waist_r filling the corners between them.
module outline_2d()
{
    offset(r = -waist_r) offset(delta = waist_r)
        union()
        {
            circle(r = body_r, $fn = 192);
            at_pod() pod_2d();
        }
}

// The board's microphones, seen from the front, in the housing
mic_pos = [for (m = mic_xy) [m[0] * cos(board_rot) - m[1] * sin(board_rot), m[0] * sin(board_rot) + m[1] * cos(board_rot)]];
// The battery's side towards the microphones
battery_side = battery_xy[0] + battery[1] / 2;

assert(battery_rot == 90, "the microphone cell and the voice port's opening are laid out for the battery upright");
assert(min([for (m = mic_pos) m[0]]) > 0, "the microphone cell is on the right, where the microphones are");

// The pod's outline, swept from the back of the body (z_back), where it's
// chin_shift closer to the center, out to the back of the pod (z_pod_back):
// the shape of the chin before it's trimmed to fit around the body
module chin_sweep(grow = 0)
{
    at_pod() translate([0, 0, z_back])
        multmatrix([[1, 0, chin_shift / chin_h, -chin_shift], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]])
            linear_extrude(chin_h) pod_2d(grow);
}

// The rest of this is in the pod's coordinates, with the speaker's long side
// along y.

module pocket_2d()
{
    rounded_rect([pocket[1], pocket[0]], spk_corner + spk_clear);
}

// Slots across the speaker, over its cone
module grille_slots_2d()
{
    pitch = grille_slot + grille_bar;
    n = floor((spk_cone[0] + grille_bar) / pitch);
    intersection()
    {
        rotate(90) offset(delta = -1) stadium(spk_cone);
        for (i = [0 : n - 1])
            translate([-spk_cone[1] / 2, (i - (n - 1) / 2) * pitch - grille_slot / 2])
                offset(r = grille_slot / 2 - 0.01) offset(delta = -(grille_slot / 2 - 0.01))
                    square([spk_cone[1], grille_slot]);
    }
}

// What's cut out of the pod: the pocket the speaker sits in, open at the
// back, with a notch in each short side for its wire, and the grille in front
// of it. The wire runs behind the speaker to the pocket's inner end, which
// overlaps the chamber, and there an opening out into the body's wall makes
// room for its plug to go through. Over the chamber, the pocket has a floor
// (pocket_floor), so the only way through is that opening.
module pod_cut()
{
    z_floor = chamber_top + pocket_floor;
    module pocket_and_notches()
    {
        pocket_2d();
        for (s = [-1, 1]) translate([-spk_wire_notch[0] / 2, s * pocket[0] / 2 - (s < 0 ? spk_wire_notch[1] : 0.01)])
            square([spk_wire_notch[0], spk_wire_notch[1] + 0.01]);
    }
    // Clear of the round part of the body, through the pod's back
    translate([0, 0, z_pod_back - 1]) linear_extrude(z_land - z_pod_back + 1) difference()
    {
        pocket_and_notches();
        translate([-pod_dist, 0]) circle(r = body_r, $fn = 192);
    }
    // Over the round part, down to the floor
    translate([0, 0, z_floor]) linear_extrude(z_land - z_floor) intersection()
    {
        pocket_and_notches();
        translate([-pod_dist, 0]) circle(r = body_r + 0.5, $fn = 192);
    }
    x0 = -pocket[1] / 2;
    z0 = chamber_top - wire_pass[1];
    intersection()
    {
        translate([x0, -wire_pass[0] / 2, z0]) cube([body_r - pod_dist - x0, wire_pass[0], z_floor + 0.5 - z0]);
        translate([-pod_dist, 0, z0 - 1]) cylinder(r = body_r - 1, h = 20, $fn = 192);
    }
    translate([0, 0, z_land - 0.01]) linear_extrude(cone_gap + 0.02) rotate(90) stadium(spk_cone);
    translate([0, 0, z_face - grille_t - 0.01]) linear_extrude(grille_t + 1) grille_slots_2d();
}

module body()
{
    // The sleeves stand in the display's pocket, so they go on after it's cut
    difference()
    {
        union()
        {
            body_shell();
            if (mic_cell) mic_sleeves();
        }
        if (mic_cell) for (m = mic_pos) translate([m[0], m[1], plate_back - 1]) cylinder(d = mic_hole, h = 10, $fn = 24);
    }
}

module body_shell()
{
    difference()
    {
        union()
        {
            // The round part behind the display, and the front slab the pod
            // is part of
            rounded_prism(z_back, z_face, edge_chamfer, front_round) circle(r = body_r, $fn = 192);
            rounded_prism(z_pod_back, z_face, slab_chamfer, front_round) outline_2d();
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
        // The chamber, around the microphones' ribs, and the rebate the back
        // sits in. In front of the battery, the ribs stop short of it.
        translate([0, 0, z_back - 1]) linear_extrude(chamber_top - z_back + 1) difference()
        {
            chamber_2d();
            if (mic_cell) mic_cell_rib_2d();
        }
        if (mic_cell)
            translate([0, 0, z_back - 1]) linear_extrude(chamber_top - battery_gap + mic_cell_rib_gap - z_back + 1)
                intersection()
                {
                    mic_cell_rib_2d();
                    battery_2d();
                }
        translate([0, 0, z_back - 1]) linear_extrude(cover_t + 1) rebate_2d();
        at_pod() pod_cut();
        for (s = cover_screws)
            translate([s[0], s[1], z_back - 1]) cylinder(d = screw_pilot, h = cover_t + 9, $fn = 16);
        at_pod() for (s = chin_screws)
            translate([s[0], s[1], z_pod_back - 1]) cylinder(d = screw_pilot, h = 7, $fn = 16);
        if (socket_marks)
            translate([0, 0, plate_back - 1]) linear_extrude(mark_depth + 1) socket_marks_2d();
        if (button_marks) button_marks();
    }
}

// The pod's back and the slope under it, trimmed to the body's outline seen
// from the front, and clear of the round part of the body
module chin()
{
    difference()
    {
        intersection()
        {
            chin_sweep();
            translate([0, 0, z_back - 1]) linear_extrude(chin_h + 2) outline_2d();
        }
        translate([0, 0, z_back - 1]) cylinder(r = body_r + 0.2, h = chin_h + 2, $fn = 192);
        // Screws into the pod's walls, their heads deep in counterbores
        at_pod() for (s = chin_screws) translate([s[0], s[1], 0])
        {
            translate([0, 0, z_back - 1]) cylinder(d = screw_clear, h = chin_h + 2, $fn = 16);
            translate([0, 0, z_back - 1]) cylinder(d = screw_head[0], h = chin_h + 1 - chin_screw_grip, $fn = 32);
        }
    }
}

// The back, with its back face at z_back
module back()
{
    difference()
    {
        translate([0, 0, z_back]) linear_extrude(cover_t) offset(delta = -0.2) rebate_2d();
        translate([0, 0, z_back - 1]) linear_extrude(cover_t + 2) mic_opening_2d();
        for (s = cover_screws) translate(s) screw_cut();
    }
    collar_posts();
}

// The pod on its own, open at the back, to try the speaker's fit and how it
// sounds
module pod_test()
{
    difference()
    {
        rounded_prism(z_pod_back, z_face, slab_chamfer, front_round) pod_2d();
        pod_cut();
    }
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

// The layout seen from the front, with the battery, cover screws and the
// board's sockets, microphones, buttons, USB-C port and micro SD slot marked
module layout()
{
    color("gray") difference()
    {
        outline_2d();
        chamber_2d();
    }
    color("orange", 0.5) battery_2d();
    color("cyan") mic_opening_2d();
    if (mic_cell) color("lime") mic_cell_rib_2d();
    rotate(board_rot)
    {
        color("red") for (a = button_angles) rotate(a) translate([cup_ir, -1.5]) square([body_r - cup_ir, 3]);
        color("blue") translate([(sd_x[0] + sd_x[1]) / 2 - sd_opening[0] / 2, cup_ir]) square([sd_opening[0], body_r - cup_ir]);
        color("blue") translate([-usb_opening[0] / 2, -body_r]) square([usb_opening[0], body_r - cup_ir]);
        color("magenta") for (m = mic_xy) translate(m) circle(d = 2);
        color("green") for (b = [spk_conn_box, bat_conn_box]) translate(b[0]) square(box_size(b));
        color("yellow") translate(header_box[0]) square(box_size(header_box));
    }
    color("purple")
    {
        for (c = cover_screws) translate(c) circle(d = screw_head[0]);
        at_pod() for (s = chin_screws) translate(s) circle(d = screw_head[0]);
    }
    color("black", 0.6) at_pod() pocket_2d();
    color("dimgray", 0.4) circle(r = cup_ir);
}

if (part == "preview")
{
    color("dimgray") body();
    color("gray") chin();
    color("gray") back();
    color("dimgray") collar();
    color("silver") washer();
    color("gray") usb_plug();
    color("midnightblue") translate([0, 0, -lens_t]) cylinder(d = lens_d, h = lens_t);
    color("red", 0.4) translate([0, 0, z_grip]) mask_keepout();
}
else if (part == "layout") layout();
// Printed back down
else if (part == "body") translate([0, 0, -z_back]) body();
// Printed on the face that meets the pod, with the slope facing up
else if (part == "chin") rotate([180, 0, 0]) translate([0, 0, -z_pod_back]) chin();
// Printed standing on its flat bottom face
else if (part == "usb_plug") translate([0, 0, -usb_recess_z[0] - usb_plug_clear]) usb_plug();
else if (part == "plungers") for (i = [0, 1]) translate([i * 8, 0, 0]) plunger();
else if (part == "plunger_test")
    for (i = [0 : len(plunger_test) - 1], j = [0, 1]) translate([i * 8, j * 8, 0]) plunger(plunger_test[i]);
else if (part == "collar") collar_print();
else if (part == "washer") washer_print();
else if (part == "gasket") gasket();
else if (part == "lens_fit") rotate([180, 0, 0]) translate([0, 0, -z_front]) lens_fit();
else if (part == "pod_test") translate([0, 0, -z_pod_back]) pod_test();
else if (part == "back") rotate([180, 0, 0]) translate([0, 0, -z_back - cover_t]) back();
