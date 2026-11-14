# Travel Cases for the 1.75" Housings

Hinged cases that carry either of the 1.75" housings with the board in it, so the display is protected in a bag:

- `low_profile_case.scad` - for the [low-profile housing](../#the-low-profile-housing): round, about 73 x 78 mm across, counting the hinge and clasp, and 36 mm tall.
- `speaker_case.scad` - for the [speaker housing](../#the-speaker-housing): shaped like it, with room for the pod below the display, about 75 x 103 mm across, counting the hinge and clasp, and 47 mm tall.

**Status: designed, not printed yet.**

## How they work

The housing lies in the case on its back, the display facing up.  Its thread drops into a round well in the floor, and the housing rests on the ledge around it, on its back (or, in the speaker housing, on the turning collar's grip), so nothing presses on the glass.  The pocket follows the housing's outline with 0.5 mm to spare all round (`case_clear`), including a notch for each plunger that stands out of its side, so the housing goes in one way round and can't turn or rattle.

Each case is two printed parts: the bottom, which holds most of the housing, and the lid, which covers its front 6 mm.  They're joined along one side by a hinge, whose pin is a length of 1.75 mm 3D printer filament, and held shut on the other side by a clasp: a springy tab on the lid with a hook that clicks under a ridge on the bottom.  To open it, pull the end of the tab outwards.

The pocket is made from the housing's own design file (`../msa_low_profile_housing.scad` or `../msa_speaker_housing.scad`), so if a housing changes, render its case again and it fits.  The case itself, the walls, hinge and clasp, is in [`hardware/common/travel_case.scad`](../../../common/travel_case.scad), shared by both, and its settings are at the top of that file.  The lid has been checked to swing open past 130 degrees without touching the bottom.

## Printing

Run `./render.sh` in this folder to render both cases to the `stl/` folder (it needs [OpenSCAD](https://openscad.org/)), or `./render.sh low_profile` or `./render.sh speaker` for one.  The parts come out turned the right way up to print, with no supports:

- **`lp_case_bottom`** or **`speaker_case_bottom`** - Printed standing on its floor.
- **`lp_case_lid`** or **`speaker_case_lid`** - Printed on its top, with the clasp's tab standing up.

**Materials:** PLA or PETG.  PETG is better for the clasp, as it bends further before it breaks.

## Putting it together

1. Line up the lid's knuckles between the bottom's.
2. Push a length of 1.75 mm filament through all five, and cut it off flush at both ends.  The holes are 2.1 mm, a snug fit.  Horizontal holes can print a little small, so if the filament won't go through, open them up with a 2 mm drill.  A touch of a soldering iron or a drop of glue on each end keeps the pin from working out.
3. Close the lid, and check the clasp clicks shut.  If it's too stiff, make `clasp_t` thinner or `clasp_len` longer.  If it doesn't hold, make `ridge` stand out further.

## Credits and License

These cases are an original design, not based on the older 1.28" and 1.46" travel cases.  Like the housings, they're licensed under the [Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International License](https://creativecommons.org/licenses/by-nc-sa/4.0/).  This is separate from the license of the rest of the repository.
