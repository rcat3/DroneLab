# Direct Comms

*The ESP32-S3-Touch-AMOLED-1.75.  New: being built, and not yet tried with two boards that can both talk.*

Direct comms carries the [comm channel](comm.md)'s voice board to board, over the radio (ESP-NOW, on the WiFi radio), with no internet, server or phone signal in between: for halls, basements and the middle of nowhere.  Each board broadcasts its wearer's voice, through the voice effect, to the boards in range, and passes what it hears from the others to its phone, which plays it to your headphones.  So a phone is still needed to listen, but it doesn't need any signal.

It's separate from the server: switching it on doesn't change anything on the server, and nothing heard directly is passed on to it.  With both on, someone in range who's also on the server is heard twice, for now.

## Switching it on

On the board, the *Direct* page in the Comm section, after Comm Setup, or in the app, the *Direct comms* card.  The board talks the same way as on the server: the talk button, holding the avatar on the status screen, voice mode, or the app's Hold to talk.  The *Direct* page lists the boards it hears, strongest first, with bars for how well.  On the status screen, with no phone, the line under the avatar says how many boards are nearby, and those talking show as RX.

## Groups

Boards that haven't been given a group are in the open group, which any board in range can hear.  To keep it to your own, in the app's *Direct comms* card, *Set group*, and give everyone the same group name and passphrase: the app turns them into a key, and the board encrypts everything with it (AES-128-GCM), so boards outside the group can neither hear it nor send to it.  The board remembers its group, and its name in it, which is your name on the server.

## Range and battery

The radio has to listen the whole time direct comms is on, which costs about 80 mA more than with it off.  Range is a few tens of metres through people and walls, more in the open.  It keeps to WiFi channel 6, the same as the board's hotspot, so the hotspot can run alongside it; joining a network on another channel, for the Voice Lab, takes the board off the others' channel while it lasts.

## Trying it with one board

A board built with `-DRCAT_DIRECT_ECHO=1` only echoes back what it hears, as a board called `ECHO-` and four letters, so one board that can talk, with its phone, hears itself come back:

```
idf.py -C platforms/esp-idf -B build-s3-146-echo -DBOARD=waveshare_esp32s3_touch_lcd_1_46 -DRCAT_DIRECT_ECHO=1 build flash
```

The 1.46" board, which can't send voice of its own, works for this.

## How it works

See the top of [`core/app/direct.h`](../../core/app/direct.h) for what's broadcast, and [`core/app/comm.h`](../../core/app/comm.h) (0x07 and 0x08) for how it reaches the phone.
