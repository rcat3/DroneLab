# HiveSight's switcher: how it's put together, and where to add things

The Guide's sender (`tools/hivesight-sender`) makes what a Vessel sees and
hears. This page is for adding to it.

## The shape

```
 sources ──► decks ──► compositor ──► encoder ──► RTP ──► Vessels
 (camera, file,  (2, with     (over black,     (permanent: never
  colour, image)  alpha)       by transition)   restarts)

 film sound ─┐
 music ──────┴─► media mixer (numpy, 10 ms) ──► RTP (media port)
```

- **The program** is one pipeline that never restarts: two decks (appsrc
  into a compositor over black), then the encoder. Its picture is always
  both eyes side by side, 2560x720. Every source is made to that format
  before it reaches a deck, so a layout (mono, side by side, top/bottom,
  half versions) is the source's business, not the Vessel's.
- **A source** (`switcher.py`, class `Source`) runs by itself and hands
  finished frames to the deck it is given (`start(slot)` / `stop()`);
  playback sources also have `set_paused`, `seek`, `position`.
- **A transition** (`Transition`) sets the decks' alphas and their film
  sound for a progress `p` from 0 to 1. The switcher waits for the new
  source's first picture, then runs the transition on a timer.
- **The media mixer** (`audiomix.py`) mixes tracks (each deck's film sound,
  each music track) with gains that ramp, and sends one stream, so the
  Vessel needs nothing new for more sound.
- **Settings** are one tree with dotted keys (`DEFAULT_STATE`). A key
  added there reaches the Guide and the Vessels, is kept by scenes if its
  section is in `SCENE_SECTIONS`, and can be reset and undone by the
  Guide's controls. `settings.py` sets one or many at once.

## Adding a transition

In `switcher.py`: subclass `Transition`, give it an `id` and a `label`,
write `apply(p, old, new)`, and add an instance to `TRANSITIONS`. The Guide
is told the list, so its menu has it and nothing else changes.

## Adding a kind of source

1. A `Source` subclass in `switcher.py` (a GStreamer pipeline ending in
   `appsink name=vsink` can use `_PipelineSource`; anything else can push
   frames with `slot.push(buffer)`).
2. In `hivesight_sender.py`: an `async def _make_x(self, spec)` that makes it
   from the Guide's spec, a cleaner in `_clean_spec`, and its entry in
   `_source_makers`.
3. Taking, cueing, queueing and the preview then work for it. The Guide's
   Source tab (`app/lib/ui/guide/panels_source.dart`) needs a tile and its
   own section for choosing it.

## Built-in sources, and files from anywhere

- A session starts on **black** (`BlackSource`, kind `black`); the camera isn't opened until it's taken.
- `switcher.BUILTINS` lists the built-in sources (id, label, file): the test pattern (`TestPatternSource`) and
  three 3D logo films, `builtin/katcorp.mp4`, `builtin/dronelab.mp4` and `builtin/katmark.mp4`, played in a loop (`LoopSource`, a
  `FileSource` that always loops). The sender tells the Guide the list (`switch.builtins`), so the Guide's
  Built-in tab shows a new one with no Dart change. To add a film: put it in `builtin/` as a side-by-side
  stereo pair (2560x720), add a line to `BUILTINS`.
- The logo films are made by `make_logo_loops.py` (see its docstring for the fonts it needs): the flat
  logo is extruded into a slab and ray-marched for each eye (two cameras turned in on it), then encoded.
  The logos with letters sway back and forth (never showing them backwards); the plain mark spins all the way
  round. They're committed; rerun it only to change a logo.
- A film's spec may carry `start` (seconds): where it starts, set from the Guide's bar while it's only
  cued. Without one it goes on from where it was left (`Switcher.resume`).
- File names in specs, and the music's, may be absolute paths: the Guide's "Choose files…" picks from
  anywhere (a thumb drive, Downloads). Relative names are still the folders' (`--media-dir`, `--music-dir`),
  which can't be escaped by `..`.

## Adding a command from the Guide

`async def _cmd_x(self, msg)` in the sender and an entry in
`_guide_commands`. On the Dart side, a method on `HiveSightGuide` that sends
`command('x', {...})`.

## Tests

`tools/hivesight-sender/tests/switcher_test.py` runs the real sender with a
test pattern, sends it commands as a Guide would, and reads back what it
sends (video decoded from RTP, sound from RTP). Add a scenario there for a
new source or transition. Run all of it with
`tools/hivesight-sender/build_fx.sh && /usr/bin/python3 tools/hivesight-sender/tests/run_tests.py`.
