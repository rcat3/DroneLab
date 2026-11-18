# Terminal

*Boards with WiFi: the ESP32-S3 boards*

The Terminal shows what's typed on the [WiFi Hotspot Remote](phone-remote.md) like an old green-screen terminal: blocky green letters that type themselves out behind a block cursor, which blinks once they're done, with faint scan lines over the screen.  It shows a `>` prompt until something's sent.

<img src="../images/screens/terminal.png" width="220" alt="The Terminal">

The letter size is picked on the phone.  *Auto* uses the biggest letters the whole message fits in (so a word or two fills the screen), down to 16 px, or pick one of 8, 16, 24, 32, 40 or 48 px.  A message too long for the size scrolls like a terminal, keeping the newest lines on screen.

The display only has plain letters, numbers and punctuation, so curly quotes and dashes become straight ones, and anything else (emoji, accents) becomes `?`.

It can be picked to show when the display turns on, in [Settings](settings.md#startup).

## Messages from others

*The ESP32-S3-Touch-AMOLED-1.75, with comms*

Others in your hive can send you messages from the *Terminal* tab of the DroneLab app, in cloud or [direct mode](comms.md#direct-mode).  Each one is added on a line of its own, after the sender's name (`Ann: hello`), and the Terminal comes on screen.  The sender can leave their name off (*Show my name*, in the app), and then it's just the message, so nobody looking at your display can tell who it's from.  The *Others* page still says who sent the last one.  They can also untick *Show on their display*, and then it only goes to your app's Terminal tab, not your display.  Every message you allow is passed on to your app's Terminal tab, either way.

Unnamed messages are shown to start with.  *Unnamed* off, on the *Others* page (titled *Hive Messages*) (or *Showing unnamed messages* in the remote's Terminal tab), leaves them off the display.

Only those you've allowed get through.  Swipe to the Terminal's second page, *Hive Messages*: anyone new who sends you a message is added there, under *Permissions*, not allowed, and you tap them to allow them (or tap again to stop), or hold them to take them off the list.  *Accept* off ignores them all and adds nobody.  The same list is under *From others* in the remote's Terminal tab.  It works as the [Lovense feature's](lovense.md#commands-from-others) list does, but is a list of its own, so someone can be allowed to send you messages without being allowed near your toys.

The Terminal's font is LVGL's 8x8 unscii font with each pixel drawn as a square block.  `tools/gen_terminal_font.py` makes `core/ui/terminal_font.c` from it.
