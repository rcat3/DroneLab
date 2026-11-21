// Phone bracer: holds a phone on the forearm, in landscape along the arm, so
// it's always to hand without pockets. It's worn on the forearm of the hand
// you don't write with, and used with the other hand. A first prototype, for
// seeing the idea and checking the fit; nothing's been printed yet.
//
// The parts:
//  - bracer: a curved plate on the top of the forearm, fitted to the arm
//    from two measurements around it, and held on by two 25 mm straps
//    through the ears on its sides. Its ends flare out, so their edges lift
//    off the suit. A dovetail rail (the land) runs along its top, turned a
//    little towards the thumb (land_tilt) so the screen faces you.
//  - mount: slides along the land, so the phone can sit nearer the wrist or
//    the elbow, and is held where it's put by one M3 x 8 screw into a row
//    of holes. It's the socket half of a quarter-turn twist lock.
//  - plug: the other half of the twist lock, screwed to the back of the
//    cradle with three M3 x 8 countersunk screws. Hold the phone at 45
//    degrees, push it onto the mount and turn it clockwise until it clicks:
//    along the arm for landscape, or across it for portrait.
//  - cradle: holds the phone by its four corners. The two at the wrist end
//    are fixed, and the two at the elbow end are on a jaw with springs
//    printed into the plate. The phone's top, with its camera, goes at the
//    wrist end, so the camera bump isn't over the springs. To put the phone in, slide its end under the
//    jaw's corners, pushing the jaw back, and lay it down; the jaw pushes it
//    into the fixed corners. To take it out, push it towards the jaw and
//    lift the other end.
//  - fit_test: two short slices of the bracer, one at each end, to check
//    the fit on the arm before printing the whole thing.
//
// Coordinates: x runs along the forearm from the wrist bone (x = 0) towards
// the elbow, z is out of the back of the forearm, and y is across it,
// towards the thumb for a left arm. The arm's drawn as an ellipse at every
// x, growing evenly from the wrist's size to the forearm's. A right arm is
// the same thing mirrored.
//
// Everything prints in PETG (PLA softens in a hot car or against a warm arm)
// with no supports:
//  - bracer: standing on its wrist end.
//  - mount: upside down, on its top face.
//  - plug: on its lugs.
//  - cradle: flat on its back.
//
// Render a part with, for example:
//   openscad -D 'part="bracer"' -o bracer.stl phone_bracer.scad

part = "preview";           // "preview", "bracer", "mount", "plug", "cradle", "ptt_lid" or "fit_test"
show_phone = true;          // in the preview
explode = 0;                // spreads the preview's parts apart by this much

include <../../common/shapes.scad>
include <phones.scad>

/* [Arm, measured over the suit] */
arm = "left";               // which forearm it's worn on: "left" or "right"
wrist_circ = 175;           // around the wrist, over the wrist bone
wrist_aspect = 1.45;        // the wrist's width over its depth, seen end on
forearm_circ = 260;         // around the forearm, forearm_dist along from the wrist bone
forearm_dist = 150;
forearm_aspect = 1.25;
fit_clear = 0.6;            // between the arm and the bracer

/* [Phone] */
phone = "Galaxy S23 in OtterBox Defender";  // a name from phones.scad, or "custom"
custom_phone = ["custom", 152, 72, 8.5, 10, [13, 7, 58, 24, 3]];   // the same layout as phones.scad
case_add = [0, 0, 0];       // a case's extra length, width and thickness, if it stays on

/* [Bracer] */
shell_t = 3;
bracer_x = [15, 175];       // where it starts and ends, from the wrist bone
wrap = 150;                 // how far round the arm it reaches, in degrees
flare = 2.5;                // how far the ends lift off the arm
flare_len = 14;
strap_w = 25;               // the straps' width
strap_slot = 4;
ear_x = [30, 153];          // where the straps go round
tab_angle = 108;            // how far round the arm the strap tabs reach, from the top
land_tilt = 0;              // degrees the land's turned towards the thumb (more crowds the talk button)
land_rise = 3;              // how far the land's top stands above the shell
land_w = 40;
land_dv = 3;                // the dovetail's depth
land_x = [35, 155];         // where the land starts and ends
lock_pitch = 10;            // between the holes for the mount's screw
mount_x = 93;               // where the mount sits, in the preview: 17 short of a screw hole

/* [Talk button: an AB Shutter3 remote, in a compartment on the thumb side] */
ptt = true;
ptt_size = [52, 33, 10.5];  // its length, width and thickness, with the strap loop
ptt_x = 47;                 // where its middle is, from the wrist bone
ptt_angle = 72;             // how far round from the top, in degrees
ptt_clr = 0.4;
ptt_wall = 3.2;             // the compartment's long walls
ptt_floor = 1.5;
ptt_chamfer = 9;            // the compartment's corners
lid_t = 2.4;
lid_dv = 1.2;               // how far the lid's edges reach under the walls
ptt_button = [-4, 0, 16];   // the remote's button: where it is from the remote's middle
                            // (towards the elbow, towards the arm's edge) and its size
ptt_nub = 0;                // a press pad under the lid's flap, down to the button, if the
                            // button sits lower than the remote's edges (it'd need the lid
                            // printed upside down)
ptt_switch = [0, 1, 14];    // a window for the power switch: where along, which wall
                            // (1 the one nearer the arm's edge, -1 the other) and how long

/* [Twist lock] */
r_neck = 14;                // the plug's neck
r_lug = 16.5;               // the plug's lugs
lug_w = 30;                 // degrees
ledge_clr = 0.3;            // round the neck, inside the ledges
cav_clr = 0.4;              // round the lugs
ledge_t = 3;
lug_t = 2.5;
lug_clr = 0.2;              // between the lugs and the ledges
detent = 0.15;              // how far the click's bump rides up over the ledge
lead_in = 0.8;
mount_size = 46;
mount_chamfer = 7;
skirt_clr = 0.3;

/* [Cradle] */
plate_t = 4;
wall = 2.2;
phone_clr = 0.3;
lip = 2.5;                  // how far the corners reach over the screen
lip_t = 1.6;
leg = 14;                   // how far each corner runs along the phone's sides
preload = 2;                // how far the phone pushes the jaw back
rail_h = 1.5;               // the side rails' height above the plate
flex_n = 6;                 // the jaw's spring beams, each side
flex_w = 2;
flex_gap = 1.5;
tongue_w = 6;

$fn = 64;
eps = 0.01;

// ---------------------------------------------------------------- the arm

// An ellipse's semi-axes from its circumference and aspect, by Ramanujan's
// approximation of the circumference: [across (y), up (z)]
function ram(k) = PI * (3 * (k + 1) - sqrt((3 * k + 1) * (k + 3)));
function semi(c, k) = let (b = c / ram(k)) [k * b, b];

w_ab = semi(wrist_circ, wrist_aspect);
f_ab = semi(forearm_circ, forearm_aspect);
function ab(x) = w_ab + (f_ab - w_ab) * x / forearm_dist;

module ell_slice(x, g)
{
    s = ab(x);
    translate([x, 0, 0]) rotate([0, 90, 0]) linear_extrude(eps)
        scale([s[1] + g, s[0] + g]) circle(1, $fn = 120);
}

module arm_model()
{
    hull() { ell_slice(-40, 0); ell_slice(260, 0); }
}

// ---------------------------------------------------------------- the bracer

stations = [[bracer_x[0], flare], [bracer_x[0] + flare_len, 0],
            [bracer_x[1] - flare_len, 0], [bracer_x[1], flare]];

module loft(g, ext = 0)
{
    n = len(stations);
    for (i = [0 : n - 2])
        hull()
        {
            ell_slice(stations[i][0] - (i == 0 ? ext : 0), g + stations[i][1]);
            ell_slice(stations[i + 1][0] + (i == n - 2 ? ext : 0), g + stations[i + 1][1]);
        }
}

g_mid = fit_clear + shell_t / 2;
function z_cut(x) = cos(wrap / 2) * (ab(x)[1] + g_mid);
function edge_y(x, fl) = let (s = ab(x), A = s[0] + g_mid + fl, B = s[1] + g_mid + fl)
    A * sqrt(1 - pow(z_cut(x) / B, 2));

module keep()
{
    hull()
        for (x = [bracer_x[0] - 20, bracer_x[1] + 20])
            translate([x, -150, z_cut(x)]) cube([eps, 300, 200]);
}

// Rounds the cut side edges
module edge_beads()
{
    for (sy = [-1, 1], i = [0 : len(stations) - 2])
        hull()
            for (st = [stations[i], stations[i + 1]])
                translate([st[0], sy * edge_y(st[0], st[1]), z_cut(st[0])])
                    sphere(d = shell_t, $fn = 24);
}

// The straps' tabs: the shell carries on round the arm under each strap,
// following it, with a slot near the end for the strap to loop through
module tab_profile(x, sy)
{
    len_x = strap_w + 1 + 8;
    zb = (ab(x)[1] + g_mid) * cos(tab_angle);
    mirror([0, sy > 0 ? 1 : 0, 0]) rotate([90, 0, 0]) linear_extrude(200)
        offset(r = 5) offset(delta = -5)
            translate([x - len_x / 2, zb]) square([len_x, z_cut(x) + 6 - zb]);
}

module tabs()
{
    for (sy = [-1, 1], x = ear_x)
        intersection()
        {
            difference() { loft(fit_clear + shell_t); loft(fit_clear, 1); }
            tab_profile(x, sy);
        }
}

module tab_slots()
{
    for (sy = [-1, 1], x = ear_x)
    {
        zb = (ab(x)[1] + g_mid) * cos(tab_angle);
        translate([x - (strap_w + 1) / 2, sy > 0 ? 0 : -200, zb + 3.5]) cube([strap_w + 1, 200, strap_slot]);
    }
}

// The land, in its own frame: turned land_tilt towards the thumb about the
// arm's axis. Its top is at hl(x) there.
function land_h(x) = let (s = ab(x), A = s[0] + fit_clear + shell_t, B = s[1] + fit_clear + shell_t)
    sqrt(pow(A * sin(land_tilt), 2) + pow(B * cos(land_tilt), 2)) + land_rise;
function hl(x) = land_h(land_x[0]) + (land_h(land_x[1]) - land_h(land_x[0]))
                 * (x - land_x[0]) / (land_x[1] - land_x[0]);
land_pitch = atan((hl(land_x[1]) - hl(land_x[0])) / (land_x[1] - land_x[0]));

module land_section(x)
{
    h = hl(x);
    d = 18;
    translate([x, 0, 0]) rotate([90, 0, 90]) linear_extrude(eps)
        polygon([[-land_w / 2, h], [land_w / 2, h], [land_w / 2 - land_dv, h - land_dv],
                 [land_w / 2 - land_dv, h - d], [-(land_w / 2 - land_dv), h - d],
                 [-(land_w / 2 - land_dv), h - land_dv]]);
}

// Places things on the land's top at x, in the mount's frame: z up out of
// the land, x along it
module on_land(x)
{
    rotate([-land_tilt, 0, 0]) translate([x, 0, hl(x)]) rotate([0, -land_pitch, 0]) children();
}

module lock_holes()
{
    for (x = [land_x[0] + 5 : lock_pitch : land_x[1] - 5])
        on_land(x) translate([0, -14, -7]) cylinder(d = 2.6, h = 8, $fn = 24);
}

// Panel lines on the bracer's outside: across it near each end, and along
// it either side of the land
panel_x = [bracer_x[0] + flare_len + 4, bracer_x[1] - flare_len - 4];
panel_angle = 52;
module panel_lines()
{
    depth = 0.6;
    intersection()
    {
        difference() { loft(fit_clear + shell_t + 2); loft(fit_clear + shell_t - depth); }
        union()
        {
            for (x = panel_x) translate([x - 0.5, -200, -200]) cube([1, 400, 400]);
            for (s = [-1, 1], dx = [0, 3])
                rotate([s * (panel_angle + dx * 1.6), 0, 0])
                    translate([panel_x[0] + dx, -0.5, 0]) cube([panel_x[1] - panel_x[0] - 2 * dx, 1, 200]);
        }
    }
}

// The talk button's compartment, in its own frame: z out of the bracer's
// side, x along the arm towards the elbow, and y towards the arm's edge.
// The remote lies in it face up, under a lid that slides on from the elbow
// end in dovetails along the long walls, and clicks into place. A flap in
// the lid presses the remote's button.
function ptt_h(x) = let (s = ab(x), A = s[0] + fit_clear + shell_t, B = s[1] + fit_clear + shell_t)
    sqrt(pow(A * sin(ptt_angle), 2) + pow(B * cos(ptt_angle), 2));
module on_side()
{
    rotate([-ptt_angle, 0, 0]) translate([ptt_x, 0, ptt_h(ptt_x)]) children();
}
ptt_cav = [ptt_size[0] + 2 * ptt_clr, ptt_size[1] + 2 * ptt_clr];
ptt_lid_z = ptt_floor + ptt_size[2] + ptt_clr;      // the lid's underside
ptt_top = ptt_lid_z + lid_t;
ptt_out = [ptt_cav[0] + 2 * 2.4, ptt_cav[1] + 2 * ptt_wall];
lid_x0 = -ptt_cav[0] / 2;                           // the lid's wrist end
module ptt_outline(grow) { stadium([ptt_size[0] + 2 * grow, ptt_size[1] + 2 * grow]); }

module ptt_box()
{
    on_side() translate([0, 0, -8]) chamfered_prism(0, 8 + ptt_top, 1) octagon2(ptt_out, ptt_chamfer);
}

// The lid's cross-section: narrower at the top, so the walls hold it down
module lid_section(grow)
{
    w = ptt_cav[1] / 2 + grow;
    polygon([[-w - lid_dv, 0], [w + lid_dv, 0], [w, lid_t], [-w, lid_t]]);
}

module lid_space()
{
    translate([lid_x0, 0, ptt_lid_z]) rotate([90, 0, 90]) linear_extrude(100) lid_section(0.25);
}

module ptt_cavity()
{
    on_side()
    {
        translate([0, 0, ptt_floor]) linear_extrude(ptt_top) ptt_outline(ptt_clr);
        lid_space();
        // The click's groove, across the elbow end wall's top
        translate([ptt_out[0] / 2 - 1.6, 0, ptt_lid_z]) rotate([90, 0, 0])
            cylinder(r = 0.6, h = ptt_cav[1], center = true, $fn = 16);
        // The power switch's window
        if (ptt_switch[2] > 0)
            translate([ptt_switch[0] - ptt_switch[2] / 2, ptt_switch[1] > 0 ? 0 : -20, ptt_floor + 2])
                cube([ptt_switch[2], 20, ptt_size[2] - 3]);
    }
}

module octagon2(size, ch)
{
    x = size[0] / 2;
    y = size[1] / 2;
    polygon([[-x + ch, -y], [x - ch, -y], [x, -y + ch], [x, y - ch],
             [x - ch, y], [-x + ch, y], [-x, y - ch], [-x, -y + ch]]);
}

// The lid, with its underside at z = 0 and the wrist end at x = 0
lid_len = ptt_out[0] / 2 - lid_x0;
flap_w = ptt_button[2] + 4;
flap_x0 = ptt_button[0] - ptt_button[2] / 2 - 2 - lid_x0;  // the flap's free end
flap_x1 = ptt_button[0] + ptt_button[2] / 2 + 10 - lid_x0; // where it's joined on
module ptt_lid()
{
    by = ptt_button[1];
    difference()
    {
        union()
        {
            rotate([90, 0, 90]) linear_extrude(lid_len) lid_section(0);
            // The press pad under the flap, and a raised hexagon on it to find by feel
            translate([ptt_button[0] - lid_x0, by, 0])
            {
                if (ptt_nub > 0) translate([0, 0, -ptt_nub]) cylinder(d = 10, h = ptt_nub + eps);
                translate([0, 0, lid_t - eps]) cylinder(d = 13, h = 1.2, $fn = 6);
            }
            // A grip to slide it off by
            for (i = [0 : 2])
                translate([lid_len - 2 - i * 2.2, -ptt_cav[1] / 2 + 3, lid_t - eps]) cube([1, ptt_cav[1] - 6, 0.8]);
        }
        // The flap: cut free on three sides
        translate([flap_x0, by, -1]) linear_extrude(lid_t + 3) difference()
        {
            translate([-0.8, -flap_w / 2 - 0.8]) square([flap_x1 - flap_x0 + 0.8, flap_w + 1.6]);
            translate([0, -flap_w / 2]) square([flap_x1 - flap_x0 + 1, flap_w]);
        }
    }
    // The click's bump
    translate([lid_len - 1.6, 0, 0]) rotate([90, 0, 0])
        cylinder(r = 0.5, h = ptt_cav[1] - 4, center = true, $fn = 16);
}

module bracer_body()
{
    difference()
    {
        union()
        {
            intersection()
            {
                difference() { loft(fit_clear + shell_t); loft(fit_clear, 1); }
                keep();
            }
            edge_beads();
            tabs();
            rotate([-land_tilt, 0, 0]) hull() { land_section(land_x[0]); land_section(land_x[1]); }
            if (ptt) ptt_box();
        }
        if (ptt) ptt_cavity();
        loft(fit_clear, 1);
        hull() { ell_slice(bracer_x[0] - 30, fit_clear + flare); ell_slice(bracer_x[0], fit_clear + flare); }
        hull() { ell_slice(bracer_x[1], fit_clear + flare); ell_slice(bracer_x[1] + 30, fit_clear + flare); }
        lock_holes();
        panel_lines();
        tab_slots();
        // Square ends, for printing standing up
        translate([bracer_x[0] - 50, -200, -200]) cube([50, 400, 400]);
        translate([bracer_x[1], -200, -200]) cube([50, 400, 400]);
    }
}

module handed()
{
    if (arm == "right") mirror([0, 1, 0]) children(); else children();
}

module bracer() { handed() bracer_body(); }

// ---------------------------------------------------------------- the twist lock

ledge_r = r_neck + ledge_clr;
cav_r = r_lug + cav_clr;
mount_h = ledge_t + lug_clr + lug_t + 0.8;
plug_h = ledge_t + lug_clr + lug_t;
ledge_half = 90 / 2 - (lug_w + 4) / 2;  // each ledge reaches this far either side of its middle
gap_w = 90 - 2 * ledge_half;

module sector(r, a0, a1, z0, z1)
{
    translate([0, 0, z0]) rotate([0, 0, a0]) rotate_extrude(angle = a1 - a0, $fn = 96)
        square([r, z1 - z0]);
}

// A wedge along a radius at angle a, from radius r0 to r1, cutting a ramp
// that's d deep at angle a and nothing at angle a + span, at height z,
// going up (dir = 1) or down (dir = -1)
module ramp(a, span, r0, r1, z, d, dir)
{
    pts = [for (r = [r0, r1])
              each [[r * cos(a), r * sin(a), z - dir * eps],
                    [r * cos(a), r * sin(a), z + dir * d],
                    [r * cos(a + span), r * sin(a + span), z - dir * eps]]];
    polyhedron(pts, [[0, 1, 2], [3, 5, 4], [0, 3, 4, 1], [1, 4, 5, 2], [2, 5, 3, 0]]);
}

// The socket, in the land's frame: its bottom on the land's top at z = 0,
// and the plug coming in from the top. Turning the plug clockwise (seen
// from above) locks it, with the lugs at 0, 90, 180 and 270 degrees.
module mount()
{
    zu = mount_h - ledge_t;     // the ledges' underside
    difference()
    {
        union()
        {
            chamfered_prism(0, mount_h, 0.8) octagon(mount_size, mount_chamfer);
            intersection()
            {
                for (sy = [-1, 1])
                    rotate([90, 0, 90]) translate([0, 0, -mount_size / 2]) linear_extrude(mount_size)
                        polygon([[sy * (land_w / 2 + skirt_clr), 0.5], [sy * mount_size / 2, 0.5],
                                 [sy * mount_size / 2, -land_dv], [sy * (land_w / 2 - land_dv + skirt_clr), -land_dv],
                                 [sy * (land_w / 2 + skirt_clr), 0]]);
                translate([0, 0, -land_dv - 1]) linear_extrude(land_dv + 2) octagon(mount_size, mount_chamfer);
            }
        }
        // The cavity the lugs turn in, open to the land, and the way in past the ledges
        translate([0, 0, -1]) cylinder(r = cav_r, h = zu + 1, $fn = 96);
        translate([0, 0, zu - eps]) cylinder(r = ledge_r, h = ledge_t + 1, $fn = 96);
        for (k = [0 : 3])
            sector(cav_r, k * 90 + 45 - gap_w / 2, k * 90 + 45 + gap_w / 2, zu - eps, mount_h + 1);
        for (k = [0 : 3])
        {
            // Lead-ins where the lugs come under the ledges, turning clockwise
            ramp(k * 90 + ledge_half, -8, ledge_r - 1, cav_r + 0.5, zu, lead_in, 1);
            // The click's groove
            rotate([0, 0, k * 90]) translate([ledge_r - 1, 0, zu - 0.9 + 0.4]) rotate([0, 90, 0])
                cylinder(r = 0.9, h = cav_r - ledge_r + 1.5, $fn = 24);
        }
        // The screw that holds it on the land, either end
        for (sx = [-1, 1])
            translate([sx * 17, -14, 0])
            {
                translate([0, 0, -1]) cylinder(d = 3.4, h = mount_h + 2, $fn = 24);
                translate([0, 0, mount_h - 3.4]) cylinder(d = 6.2, h = 4, $fn = 32);
            }
        // A ring round the top, for looks
        translate([0, 0, mount_h - 0.5]) difference()
        {
            cylinder(r = cav_r + 3.2, h = 1, $fn = 96);
            cylinder(r = cav_r + 2.4, h = 1, $fn = 96);
        }
        // Marks: where the plug goes in for landscape, and which way to turn
        translate([mount_size / 2 - 5.5, mount_size / 2 - 5.5, mount_h - 0.6])
            rotate([0, 0, 45]) linear_extrude(1) polygon([[-1.6, -2], [1.6, -2], [0, 2]]);
    }
    // Stops at the end of the turn
    for (k = [0 : 3])
        sector(cav_r + 0.2, k * 90 - ledge_half, k * 90 - lug_w / 2 - 0.4, 0, zu + eps);
}

module mount_stops_clear() { translate([0, 0, -1]) cylinder(r = ledge_r, h = 20, $fn = 96); }

module mount_part()
{
    difference() { mount(); mount_stops_clear(); }
}

module octagon(s, ch)
{
    h = s / 2;
    polygon([[-h + ch, -h], [h - ch, -h], [h, -h + ch], [h, h - ch],
             [h - ch, h], [-h + ch, h], [-h, h - ch], [-h, -h + ch]]);
}

// The plug, with the back of the cradle at z = 0 and the plug below it
module plug()
{
    zt = -ledge_t - lug_clr;    // the lugs' top
    difference()
    {
        union()
        {
            translate([0, 0, -plug_h]) cylinder(r = r_neck, h = plug_h, $fn = 96);
            for (k = [0 : 3])
            {
                sector(r_lug, k * 90 - lug_w / 2, k * 90 + lug_w / 2, -plug_h, zt);
                // The click's bump, along the lug's middle
                intersection()
                {
                    rotate([0, 0, k * 90]) translate([r_neck - 1, 0, zt - 0.8 + lug_clr + detent])
                        rotate([0, 90, 0]) cylinder(r = 0.8, h = r_lug - r_neck + 1, $fn = 24);
                    cylinder(r = r_lug - 0.3, h = 20, center = true, $fn = 96);
                }
            }
        }
        for (k = [0 : 3])   // the lugs' leading edges, turning clockwise
            ramp(k * 90 - lug_w / 2, 8, r_neck - 0.5, r_lug + 0.5, zt, lead_in, -1);
        for (a = [30, 150, 270])
            rotate([0, 0, a]) translate([8, 0, -6]) cylinder(d = 2.6, h = 7, $fn = 24);
        // A chamfer round the bottom, to find the way in
        translate([0, 0, -plug_h - eps]) difference()
        {
            cylinder(r = r_lug + 1, h = 0.6);
            cylinder(r1 = r_neck - 0.6, r2 = r_neck, h = 0.6, $fn = 96);
        }
    }
}

// ---------------------------------------------------------------- the cradle

pp = phone == "custom" ? custom_phone : phone_preset(phone);
P = [pp[1] + case_add[0], pp[2] + case_add[1], pp[3] + case_add[2]];
L = P[0];
W = P[1];
T = P[2];
rc = pp[4];
cam = pp[5];
cup_top = plate_t + T + phone_clr + lip_t;
x_cb0 = L / 2 - preload - leg;      // where the jaw's crossbar starts
flex_len = flex_n * (flex_w + flex_gap) + flex_gap;
x_pe = x_cb0 - flex_len;            // where the fixed plate ends
y_in = tongue_w / 2 + 2;
y_out = min(y_in + 22, W / 2 - 4);

// The cradle's outside: square corners cut off at 45 degrees
module shell_outline()
{
    g = phone_clr + wall;
    c = rc * 0.6 + wall;
    x = L / 2 + g;
    y = W / 2 + g;
    polygon([[-x + c, -y], [x - c, -y], [x, -y + c], [x, y - c],
             [x - c, y], [-x + c, y], [-x, y - c], [-x, -y + c]]);
}

module outline(grow)
{
    rounded_rect([L + 2 * grow, W + 2 * grow], max(rc + grow, 0.5));
}

// The corners at one end (sx = -1 the fixed end, 1 the jaw's)
module corners(sx)
{
    intersection()
    {
        difference()
        {
            chamfered_prism(0, cup_top, 0.8) shell_outline();
            translate([0, 0, plate_t]) linear_extrude(T + phone_clr) outline(phone_clr);
            translate([0, 0, plate_t]) linear_extrude(cup_top) outline(-lip);
            // A chamfer round the lips' edges
            translate([0, 0, cup_top - 0.8]) linear_extrude(1) outline(-lip + 0.8);
            translate([0, 0, cup_top - 0.4]) linear_extrude(1) outline(-lip + 1.2);
        }
        for (sy = [-1, 1])
            translate([sx > 0 ? L / 2 - leg : -L / 2 - 10, sy > 0 ? W / 2 - leg : -W / 2 - 10, -1])
                cube([leg + 10, leg + 10, cup_top + 2]);
    }
}

module camera_cut()
{
    // From the front with the phone's top at -x, its back's left is +y
    c = [cam[0], cam[1], cam[2], cam[3]];
    margin = 1.5;
    x0 = -L / 2 + c[0] - margin;
    x1 = -L / 2 + c[0] + c[3] + margin;
    y1 = W / 2 - c[1] + margin;
    y0 = W / 2 - c[1] - c[2] - margin;
    depth = min(cam[4] + 0.5, plate_t - 1);
    // Right through where the plate's well inside the phone...
    intersection()
    {
        translate([x0, y0, -1]) cube([x1 - x0, y1 - y0, plate_t + 2]);
        translate([0, 0, -1]) linear_extrude(plate_t + 2) outline(-6);
    }
    // ...and a pocket where it isn't, so the corners stay joined to the plate
    intersection()
    {
        translate([x0, y0, plate_t - depth]) cube([x1 - x0, y1 - y0, depth + 1]);
        linear_extrude(plate_t + 2) outline(phone_clr);
    }
}

module fixed_frame()
{
    difference()
    {
        union()
        {
            intersection()
            {
                linear_extrude(plate_t) shell_outline();
                translate([-L, -W, -1]) cube([L + x_pe, 2 * W, plate_t + 2]);
            }
            corners(-1);
            // Side rails joining the fixed corners to the plate
            intersection()
            {
                difference()
                {
                    chamfered_prism(0, plate_t + rail_h, 0.6) shell_outline();
                    translate([0, 0, plate_t]) linear_extrude(rail_h + 1) outline(phone_clr);
                }
                translate([-L / 2, -W, -1]) cube([L / 2 + x_pe, 2 * W, cup_top]);
            }
        }
        camera_cut();
        // The slot the jaw's tongue slides in
        translate([x_pe - 11, -tongue_w / 2 - 0.4, -1]) cube([12, tongue_w + 0.8, plate_t + 2]);
        // Countersunk screws into the plug
        for (a = [30, 150, 270])
            rotate([0, 0, a]) translate([8, 0, 0])
            {
                translate([0, 0, -1]) cylinder(d = 3.4, h = plate_t + 2, $fn = 24);
                translate([0, 0, plate_t - 1.7]) cylinder(d1 = 3.4, d2 = 6.8, h = 1.71, $fn = 32);
            }
        // Panel lines
        for (sy = [-1, 1])
            translate([-L / 2 + leg + 4, sy * (W / 2 - 9) - 0.4, plate_t - 0.6])
                cube([x_pe - (-L / 2 + leg + 4) - 14, 0.8, 1]);
    }
}

module jaw()
{
    translate([-preload, 0, 0])
    {
        corners(1);
        intersection()
        {
            linear_extrude(plate_t) shell_outline();
            translate([L / 2 - leg, -W, -1]) cube([leg + 10, 2 * W, plate_t + 2]);
        }
        // A tab to pull it back with
        difference()
        {
            hull()
                for (sy = [-1, 1])
                    translate([L / 2 + phone_clr + wall, sy * 6, 0]) cylinder(r = 3, h = plate_t);
            for (i = [0 : 2])
                translate([L / 2 + phone_clr + wall + 0.5 + i * 1.6, -10, plate_t - 0.5]) cube([0.7, 20, 1]);
        }
    }
    // The tongue that keeps it in line
    translate([x_pe - 10, -tongue_w / 2, 0]) cube([x_cb0 - x_pe + 10 + eps, tongue_w, plate_t]);
}

// Two springs of beams across the phone, one each side of the tongue
module springs()
{
    for (sy = [-1, 1])
        mirror([0, sy < 0 ? 1 : 0, 0])
        {
            l = y_out - y_in;
            for (i = [0 : flex_n - 1])
                translate([x_pe + flex_gap + i * (flex_w + flex_gap), y_in, 0]) cube([flex_w, l, plate_t]);
            for (j = [0 : flex_n])
            {
                x0 = j == 0 ? x_pe - 0.5 : x_pe + flex_gap + (j - 1) * (flex_w + flex_gap);
                x1 = j == flex_n ? x_cb0 + 0.5 : x_pe + flex_gap + j * (flex_w + flex_gap) + flex_w;
                translate([x0, j % 2 == 0 ? y_in : y_out - flex_w, 0]) cube([x1 - x0, flex_w, plate_t]);
            }
        }
}

module cradle()
{
    fixed_frame();
    jaw();
    springs();
}

module phone_model()
{
    color("#141418") translate([0, 0, plate_t]) linear_extrude(T) outline(0);
    color("#00e5ff", 0.55) translate([0, 0, plate_t + T - 0.2]) linear_extrude(0.3) outline(-1.5);
}

// ---------------------------------------------------------------- the parts

module stand_up(x0)
{
    rotate([0, -90, 0]) translate([-x0, 0, 0]) children();
}

module ptt_model()
{
    on_side()
    {
        translate([0, 0, ptt_floor]) color("#e8e8ec") linear_extrude(ptt_size[2] - 0.8) ptt_outline(0);
        translate([ptt_button[0], ptt_button[1], ptt_floor + ptt_size[2] - 0.8]) color("#2a6cff") cylinder(d = ptt_button[2], h = 0.8);
        translate([lid_x0, 0, ptt_lid_z + explode * 0.4]) color("#7a7a86") ptt_lid();
    }
}

module assembly()
{
    color("#c9a7a0", 0.25) arm_model();
    color("#55555f") bracer();
    if (ptt) handed() ptt_model();
    handed() on_land(mount_x)
    {
        translate([0, 0, explode * 0.6]) color("#7a7a86") mount_part();
        translate([0, 0, mount_h + explode * 1.2])
        {
            color("#ff2d95") plug();
            translate([0, 0, explode * 0.6])
            {
                color("#44444d") cradle();
                if (show_phone) translate([0, 0, explode * 0.8]) phone_model();
            }
        }
    }
}

if (part == "preview") assembly();
else if (part == "bracer") stand_up(bracer_x[0]) bracer();
else if (part == "mount") rotate([180, 0, 0]) translate([0, 0, -mount_h]) mount_part();
else if (part == "plug") translate([0, 0, plug_h]) plug();
else if (part == "cradle") cradle();
else if (part == "ptt_lid") ptt_lid();
else if (part == "fit_test")
{
    stand_up(bracer_x[0]) intersection() { bracer(); translate([bracer_x[0] - 1, -200, -200]) cube([22, 400, 400]); }
    translate([0, 120, 0]) stand_up(bracer_x[1] - 20)
        intersection() { bracer(); translate([bracer_x[1] - 21, -200, -200]) cube([22, 400, 400]); }
}
else if (part != "none") assert(false, str("Unknown part \"", part, "\""));
