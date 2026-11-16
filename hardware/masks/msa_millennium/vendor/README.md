# The Older Voice Port Thread

`vpu_thread.stl` is the voice port thread from [RP2040-LCD-1.28-MSA](https://www.printables.com/model/538771-rp2040-lcd-128-msa) by whyrlpool, which adapted it from the [Gas Mask VPU Cover (MSA compatible)](https://cults3d.com/en/3d-model/various/gas-mask-vpu-cover-msa-compatible).  It's been cleaned up into a single solid, and the original's inner lip has been removed so the inside is a plain 42 mm bore.  `vpu_thread_mesh.scad` loads it.

The current housings don't use it: their thread is drawn in [`../voice_port.scad`](../voice_port.scad).  It's kept for comparing against (the MESH ring in `thread_test.scad`), and it's what the deprecated housings were printed with.

## License

Like the design it's from, the files in this folder are licensed under the [Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International License](https://creativecommons.org/licenses/by-nc-sa/4.0/).  So is anything printed or exported with this thread in it, such as a housing rendered with `thread_model = "mesh"`, or the MESH test ring.  This is separate from the license of the rest of the repository.
