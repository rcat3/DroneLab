// The MSA Millennium's voice port thread, shared by every housing that
// screws into the mask. Include this file.
//
// The thread is drawn here (vpu_thread_solid() below), and the housings use
// it. The older thread, vendor/vpu_thread.stl, is
// the mesh from whyrlpool's 1.28" design, under its own license (see
// vendor/README.md). It's kept to compare against, and thread_model picks
// which one is used.
//
// Either way, the thread's front face is at z = 0 and it screws into the mask
// from the z = 8 end. Its outside is the thread; its inside is a plain bore.

use <vendor/vpu_thread_mesh.scad>

thread_model = "drawn";     // "drawn": vpu_thread_solid(), from the settings below; "mesh": vendor/vpu_thread.stl
thread_scale = 0.997;       // scales the thread's diameter. From the test rings: 99.7% fits best
                            // (98% is too loose, 102% doesn't fit)
thread_lead_in = [1.5, 1.2];  // bevel on the start of the thread (length, depth) to help it catch
thread_length = 8;          // how far the thread reaches into the port

/* [The drawn thread] */
// At 100%; thread_scale scales the diameters.
vpu_major_d = 52.0;         // across the crests
vpu_depth = 0.8;            // from crest to root, so the root is 50.4 mm across
vpu_pitch = 3.63;           // along the axis, per turn
vpu_crest = 0.55;           // the flat on top of each crest, along the axis
vpu_root = 0.35;            // the flat at the bottom of each groove; the flanks between are rounded
vpu_hand = 1;               // 1: right-handed, -1: left-handed
vpu_phase_z = 3.52;         // where a crest's middle is on the +x side, from the front face. This
                            // sets which way round a housing ends up when it's screwed in
vpu_bore_d = 42;            // the plain bore inside
vpu_steps = [240, 0.1];     // facets around, and the step along the axis

// The thread at scale s, with the start of it beveled so it catches more
// easily
module vpu_thread(s = thread_scale, model = thread_model)
{
    thread_r = vpu_major_d / 2 * s;
    difference()
    {
        if (model == "drawn") vpu_thread_solid(s);
        else scale([s, s, 1]) vpu_thread_mesh();
        translate([0, 0, thread_length - thread_lead_in[0]])
            difference()
            {
                cylinder(r = thread_r + 2, h = thread_lead_in[0] + 1);
                translate([0, 0, -0.01])
                    cylinder(r1 = thread_r + 0.01, r2 = thread_r - thread_lead_in[1], h = thread_lead_in[0] + 0.02);
            }
    }
}

// The thread's radius at angle a (degrees) and height z, at 100%. u counts
// pitches from the middle of a crest; x is the distance along the axis from
// the nearest crest's middle.
function vpu_thread_r(a, z) =
    let (u = (z - vpu_phase_z - vpu_hand * vpu_pitch * a / 360) / vpu_pitch,
         x = abs(u - floor(u + 0.5)) * vpu_pitch,
         flank = (vpu_pitch - vpu_crest - vpu_root) / 2,
         t = min(max((x - vpu_crest / 2) / flank, 0), 1))
    vpu_major_d / 2 - vpu_depth * (1 - cos(180 * t)) / 2;

// The drawn thread: a tube whose outside follows vpu_thread_r(), as one
// polyhedron. Rings of points around the outside, a step apart along the
// axis, then a ring at each end of the bore.
module vpu_thread_solid(s = 1)
{
    n = vpu_steps[0];
    m = ceil(thread_length / vpu_steps[1]);
    rb = vpu_bore_d / 2 * s;
    outer = [for (j = [0 : m], i = [0 : n - 1])
                let (a = 360 * i / n, z = thread_length * j / m, r = vpu_thread_r(a, z) * s)
                [r * cos(a), r * sin(a), z]];
    inner = [for (j = [0, 1], i = [0 : n - 1])
                let (a = 360 * i / n) [rb * cos(a), rb * sin(a), j * thread_length]];
    o = function (j, i) j * n + (i % n);
    b = function (j, i) (m + 1) * n + j * n + (i % n);
    faces = concat(
        [for (j = [0 : m - 1], i = [0 : n - 1], f = [[o(j, i), o(j + 1, i), o(j + 1, i + 1)],
                                                     [o(j, i), o(j + 1, i + 1), o(j, i + 1)]]) f],
        [for (i = [0 : n - 1], f = [[b(0, i), o(0, i), o(0, i + 1)],
                                    [b(0, i), o(0, i + 1), b(0, i + 1)]]) f],
        [for (i = [0 : n - 1], f = [[o(m, i), b(1, i), b(1, i + 1)],
                                    [o(m, i), b(1, i + 1), o(m, i + 1)]]) f],
        [for (i = [0 : n - 1], f = [[b(1, i), b(0, i), b(0, i + 1)],
                                    [b(1, i), b(0, i + 1), b(1, i + 1)]]) f]);
    polyhedron(concat(outer, inner), faces, convexity = 6);
}

// Thin thread rings at a few scales, to find the best fit in the mask. Each
// has a bar across it to grip, so it can be screwed all the way in and out.
// models picks the thread for each ring, the same for all of them by default.
module thread_test(scales = [0.994, 0.997, 1.000], models = undef)
{
    for (i = [0 : len(scales) - 1])
        translate([i * 56, 0, 0])
        {
            vpu_thread(scales[i], models == undef ? thread_model : models[i]);
            translate([-21.5, -2.5, 0]) cube([43, 5, 6]);
            // Notches on the rim say which ring it is: 1 to 3
            for (n = [0 : i])
                rotate([0, 0, n * 8]) translate([0, 21.2, 7.2]) cube([1.2, 1.5, 1.6]);
        }
}
