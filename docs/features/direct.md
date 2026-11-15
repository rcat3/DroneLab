# Direct Comms

*The ESP32-S3-Touch-AMOLED-1.75.  New: being built, and not yet tried with two boards that can both talk.*

Direct comms carries the [comm channel](comm.md)'s voice board to board, over the radio (ESP-NOW, on the WiFi radio), with no internet, server or phone signal in between: for halls, basements and the middle of nowhere.  Each board broadcasts its wearer's voice, through the voice effect, to the boards in range, and passes what it hears from the others to its phone, which plays it to your headphones.  So a phone is still needed to listen, but it doesn't need any signal.

It's separate from the server: nothing heard directly is passed on to it, or the other way.  You hear both at once: the app plays the server's voices and direct comms' together.

## Talk on

Talking goes one way at a time: to the server, or direct.  *Talk on*, above the app's Hold to talk, or on the board's *Direct* page, says which.  If nobody's on that one to hear you (the server isn't connected, or nobody else is in your channel; or no boards of your group are nearby) and somebody's on the other, it goes the other way instead, and the app says so under the choice.  That's decided as you start talking, and doesn't change partway through.  On the board's status screen, while you talk, a cloud (the server) or a handheld radio (direct) shows where it's going, with the channel's or group's name.

## Switching it on

On the board, the *Direct* page in the Comm section, after Comm Voice, or in the app, the *Direct* line on the Comm tab.  The board talks the same way as on the server: the talk button, holding the avatar on the status screen, voice mode, or the app's Hold to talk.  The *Direct* page lists the boards it hears, strongest first, with bars for how well.  On the status screen, with no phone, the line under the avatar says how many boards are nearby, and those talking show as RX.

## Groups

Boards start in the **open group**, which any board in range can hear.  To keep it to your own, use a group with a passphrase: in the app, *Direct* on the Comm tab, or *Comm Settings*, then the group.

- **Create a group**: give it a name, which others nearby can see, and a passphrase, which they'll need to join.  A few unrelated words make a good passphrase.
- **Heard nearby**: every board in a group says so every couple of seconds, with its group's name (not its passphrase), so the groups about show up in the list, with how many boards are in each.  Tap one and type its passphrase to join; a wrong one's caught straight away, without trying it on the air.
- **Your groups**: those made or joined on this phone, to switch between.  *Delete* takes one off this phone; it carries on for anyone else who has its passphrase.

The app turns the group's name and passphrase into a key (PBKDF2, deliberately slow), and the board encrypts everything with it (AES-128-GCM), so boards outside the group can neither hear it nor send to it, however they're changed.  The passphrase never leaves the phone.  What's not hidden: that a group's there, its name, and how many are in it; and anyone who's been given the passphrase is in it, so start a new group if someone shouldn't be any more.  The board keeps its group's key in its settings, so someone with the board itself could read it out.

## Channels and Long Range

Each group has a radio channel, 1, 6 or 11 (the three that don't overlap), and can use **Long Range**, Espressif's own slower mode (500 kb/s) that reaches further, at the cost of each packet taking about twice as long on the air.  Both are chosen when the group's made, and come with it to everyone who joins.  The open group is on channel 6, in Long Range.  Every board hears both ordinary and Long Range broadcasts, so it doesn't matter which a board in the group sends.  Putting a busy group on its own channel keeps it from crowding the open group.

A board only hears its own channel, so opening the app's Groups screen has it listen on each of the three for a couple of seconds, to find the groups on the others; what's said on its own meanwhile is missed.  It can't while the hotspot's on.  The hotspot moves to the group's channel, if it's on.

## Relaying

A board that hears one of its group's broadcasts only weakly, as from the edge of its range, passes it on once, after a short random wait, unless it hears another board do so first.  So two boards just out of range of each other still hear each other through one in between, without every board repeating everything.

## Avatars

Each board sends its wearer's [avatar](comm.md#avatars) to the others in its group, at the size the board shows it (112x112), a little at a time.  The pixels go every eighth one each way first, then every fourth, every second and the rest, so a talker shows straight away as big blocks of their picture, which sharpen as more comes in.  All of it goes soon after a new board's heard and every five minutes, about twenty seconds' worth of small packets; the coarsest two layers go every half minute; and none of it while the wearer's talking.  Any pieces that don't arrive, a board asks for again in its next hello, and they're sent again between other broadcasts, so a picture fills in within seconds.  So direct talkers show with their own picture even with no server.  The board needs its phone to have given it the avatar once since it started.

## Range and battery

The radio has to listen the whole time direct comms is on, which costs about 80 mA more than with it off.  Range is a few tens of metres through people and walls, more in the open, and more again with Long Range or an antenna outside the mask.  Joining a network on another channel, for the Voice Lab, takes the board off the group's channel while it lasts.

## Trying it with one board

A board built with `-DRCAT_DIRECT_ECHO=1` only echoes back what it hears, as a board called `ECHO-` and four letters, so one board that can talk, with its phone, hears itself come back.  Once it's had a whole avatar, it takes that on as its own, so the avatar comes back too.  It's in a group called *Echo Test*, with the passphrase `dronelab`, which shows up as heard nearby, for trying joining one:

```
idf.py -C platforms/esp-idf -B build-s3-146-echo -DBOARD=waveshare_esp32s3_touch_lcd_1_46 -DRCAT_DIRECT_ECHO=1 build flash
```

The 1.46" board, which can't send voice of its own, works for this.

## How it works

See the top of [`core/app/direct.h`](../../core/app/direct.h) for what's broadcast, and [`core/app/comm.h`](../../core/app/comm.h) (0x07 and 0x08) for how it reaches the phone.
