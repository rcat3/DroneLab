# Travel Cases for the 1.75" Housings

Hinged cases that carry either of the 1.75" housings with the board in it, so the display is protected in a bag:

- `low_profile_case.scad` - for the [low-profile housing](../#the-low-profile-housing): round, about 74 x 88 mm across, counting the hinge and clasp, and 36 mm tall.
- `speaker_case.scad` - for the [speaker housing](../#the-speaker-housing): shaped like it, with room for the pod below the display, about 76 x 112 mm across, counting the hinge and clasp, and 47 mm tall.

**Status:** the speaker housing's case is printed and works.  The low-profile housing's is designed, not printed yet.

## How they work

The housing lies in the case on its back, the display facing up.  Its thread drops into a round well in the floor, and the housing rests on the ledge around it, on its back (or, in the speaker housing, on the turning collar's grip), so nothing presses on the glass.  The pocket follows the housing's outline with 0.5 mm to spare all round (`case_clear`), including a notch for each plunger that stands out of its side, so the housing goes in one way round and can't turn or rattle.

Each case is three printed parts: the bottom, which holds most of the housing, the lid, which covers its front 6 mm, and the clasp.  The bottom and lid are joined along one side by a hinge, whose pin is a length of 1.75 mm 3D printer filament.  On the other side, the clasp is a lever that turns on a second filament pin in two ears on the lid, and its lower end is a C that snaps round a 4.2 mm bar on the bottom, like the clasp on the older 1.28" and 1.46" cases.  To open it, pull the grip below the C outwards.

Where the bottom and lid meet, the inner part of the bottom's wall stands up 1.5 mm past the seam as a lip, 1 mm wide, and fits into a rebate in the lid's wall with 0.2 mm to spare, so the lid can't shift sideways and the seam is closed all round.  The lid's wall outside the lip comes down over it to the seam.  The walls are 2.4 mm thick, to leave room for both.  Nothing bends but the C's jaws, by 0.15 mm each, and the clasp prints on its side, so the C's layers run round it, its strongest way.  If it wears, it's a quick reprint.

The pocket is made from the housing's own design file (`../msa_low_profile_housing.scad` or `../msa_speaker_housing.scad`), so if a housing changes, render its case again and it fits.  The case itself, the walls, hinge and clasp, is in [`hardware/common/travel_case.scad`](../../../common/travel_case.scad), shared by both, and its settings are at the top of that file.  The lid has been checked to swing open past 130 degrees without touching the bottom.

## Printing

Run `./render.sh` in this folder to render both cases to the `stl/` folder (it needs [OpenSCAD](https://openscad.org/)), or `./render.sh low_profile` or `./render.sh speaker` for one.  The parts come out turned the right way up to print, with no supports:

- **`lp_case_bottom`** or **`speaker_case_bottom`** - Printed standing on its floor.
- **`lp_case_lid`** or **`speaker_case_lid`** - Printed on its top.
- **`lp_case_clasp`** or **`speaker_case_clasp`** - Printed on its side, 14 mm tall.  The two cases' clasps are the same.

**Materials:** PLA, PLA+ or PETG.

## Putting it together

1. Line up the lid's knuckles between the bottom's.
2. Push a length of 1.75 mm filament through all five, and cut it off flush at both ends.  The holes are 2.1 mm, a snug fit.  Horizontal holes can print a little small, so if the filament won't go through, open them up with a 2 mm drill.  A touch of a soldering iron or a drop of glue on each end keeps the pin from working out.
3. Put the clasp between the lid's ears, the C at the bottom with its mouth towards the case, and push filament through the ears and the clasp the same way.  The ears' holes are 2.1 mm, and the clasp's 2.3 mm, so it turns freely.
4. Close the lid, swing the clasp in, and press the C onto the bar until it snaps on.  If it's too stiff, make `snap` smaller.  If it doesn't hold, make it bigger.  Both are at the top of `hardware/common/travel_case.scad`.

## Credits and License

These cases are an original design.  Their clasp works the same way as the older 1.28" and 1.46" travel cases' clasp, a lever with a C that snaps round a bar, but it's drawn from scratch, not taken from those files.  Like the housings, they're by Rubber Cat, and licensed under the [Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International License](https://creativecommons.org/licenses/by-nc-sa/4.0/).  This is separate from the license of the rest of the repository.
