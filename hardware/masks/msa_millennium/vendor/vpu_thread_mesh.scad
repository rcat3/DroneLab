// The older thread's mesh, from whyrlpool's RP2040-LCD-1.28-MSA (see README.md
// in this folder for its credits and license). It's in a file of its own,
// brought in with `use`, so the path below is found relative to this folder
// whichever housing includes voice_port.scad.
module vpu_thread_mesh() import("vpu_thread.stl", convexity = 10);
