# Vibe Patterns

Make your own patterns for Vibe toys, keep the ones others send you, and pick favourites for your own unit.  It's in **Setup**, under *Toys*, and behind the **Patterns** button on [HiveMind Control](control.md)'s Patterns tab.

Back to [the app](README.md).

## The library

- **Yours**: the patterns you've made, each with a small picture of its shape.  Tap one to change it.  Its **⋮** has *Duplicate*, *Copy in Lovense's format* and *Delete*.
- **Built in**: the six every unit has (*Wave*, *Pulse*, *Heartbeat*, *Climb*, *Surge*, *Wander*).  Tap one to make a pattern of yours from it.
- **Sent to you**: patterns others have played on your toys, or shared with you in a message, with who sent them.  The newest are kept.

**+** makes a new one, and **Import** takes one in Lovense's pattern format, pasted in (whatever's on the clipboard is filled in for you).

## Favourites

Tap a pattern's **☆** to make it a favourite.  Your favourites go to your unit whenever they change and each time it connects, and it keeps them when it restarts: they're first on its [Patterns](../features/toys.md) page, before the built-in ones, and on the [WiFi remote](../features/phone-remote.md)'s.  They're on HiveMind Control's Patterns tab too, with your own.  The line at the top says how many are on your unit and how much of its room they take (16 KB, about 50 patterns of a usual size).  One that doesn't fit is marked so.

A unit keeps favourites only once it's had its firmware flashed over USB since they were added; until then the line says so, and it forgets them when it restarts.

## Making one

A pattern has up to six **rows**.  With one row, it plays on every channel it's played on.  With more, its first row plays on the first channel (the lowest), its second row on the next, and so on, so one pattern can run V1 and V2 in turns.  Each row is a graph: time across, level up, 0 to 20.

- **Draw**: draw along a row to set its levels, or tap one step.
- **Select**: drag across steps to pick them, and down over the rows for more rows.  Tap to let go of them.  Then:
  - **Ramp up**, **Ramp down**, **Wave**, **Pulse**, **Heartbeat** and **Random** fill them with a shape, and **Smooth** rounds them off.  **Off** sets them to 0.
  - **Copy** and **Paste** (after the selection), **Repeat** (a copy straight after it) and **Delete**.
- **Undo**, at the top, takes back the last change.  The magnifiers zoom in and out, and the bar beside them moves along a long pattern.
- **Rows share timing**, on to start with, keeps every row's steps the same length and every row as long, so they stay in step.  Off, each row has its own step length and number of steps, so rows of different lengths drift against each other as they repeat.  A step is 100 ms or more.
- **Preview** plays it with a line moving across each row, and on your own unit's toys too unless you switch that off.
- The **meter** shows how much of the room there is for one pattern it takes (636 bytes, about 1,000 steps in all), and whether it's small enough to share in a message.

✓ saves it.  A built-in pattern, or one sent you, is saved as a new one of yours.

## Playing one on others' toys

On HiveMind Control's *PATTERNS* tab ([Toys](control.md#toys)), yours and your starred ones come after the built-in ones.  A custom pattern goes to their unit along with the command that plays it, and again every 30 seconds while it plays, so whoever joins later or missed it gets it too.  Their unit waits for it before playing, and keeps it, so their app has it under *Sent to you*.

## Sharing one

In a conversation, **⋮** → **Share a pattern** sends one of yours as a text.  It shows as the pattern's shape with a **Save** button, which puts it in their library.  It has to fit in one text over direct mode, so long patterns can't be shared this way; the meter says which ones can.

## Lovense's format

Patterns go in and out in Lovense's pattern format, so ones written for their tools work:

```
V:1;F:v1,v2;S:200#20,0;0,20;20,0;0,20;
```

`S` is how long each step lasts, in milliseconds.  After the `#` come the steps, separated by `;`, each with a level from 0 to 20 for each of `F`'s motors, separated by `,`.  A number after a motor's letter is its row, whatever the letter: `v2` is row 2.  A single motor with no number plays on every channel.  A pattern can hold several parts one after another, each with its own `F` and `S`, repeating at its own length.
