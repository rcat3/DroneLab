# Control

Control runs other drones' [Lovense](../features/lovense.md) toys, through their units: over the server or over direct mode, wherever they are.  It only works on toys whose wearers have [allowed you](#who-can-control-your-toys).

<img src="../images/app/control.png" width="300" alt="Control for one drone: Levels, Patterns and React, a slider for each kind of motor, and STOP">

Back to [the app](README.md).  Running *your own* toys is on your unit's [Lovense](../features/lovense.md) feature, or the [Remote](remote.md) tab's *Toys*.

## Sending

Open it with the **Control button** at the top of a [Text](text.md) conversation: it's for whoever that conversation is with, which it says at the top.  From a person's conversation it's their toys, sent both ways they can be reached (their unit does each once, by whichever way it allows); from a channel's, the toys of everyone in it; from *Broadcast*, everyone who can hear you.  The *Control* button on someone in the [Voice](voice.md#whos-there) list opens it for them too.

Then one of three sections:

- **LEVELS**: a slider for each kind of motor, from 0 to 20: *VIBRATE*, *ROTATE*, *PUMP* and *THRUST*.  Each toy runs the motors it has, and 20 is each motor's top.  The levels also set how high Patterns and React go.
- **PATTERNS**: plays a pattern on their toys, if their unit has one by that name: the six built-in ones always do (*Wave*, *Pulse*, *Heartbeat*, *Climb*, *Surge*, *Wander*), and patterns from an SD card only if theirs has one with the same name.  The list is your unit's.  *SPEED* runs them from 25% to 300%.
- **REACT**: their toys follow **their own** voice or movement, as their unit senses it: *VOICE*, *MOVING*, *STILL*, *MOTION* or *TILT* (see [React to](../features/lovense.md) for what each does).  It keeps going until it's changed or stopped.

**STOP**, always at the foot of the screen, stops everything on their toys at once: levels, patterns and reactions.  It says *STOPPED* once it's gone.

What you set stays set on their toys until it's changed or stopped, even once you've closed Control.  Each one is noted in your conversation with them, and in theirs with you.  Each command is sent again a moment later, in case the first was lost.  Over the server, it needs a Mumble server from version 1.4 on.

## Who can control your toys

The same works the other way, and you choose whose commands your toys take, with **Off**, **Ask** or **Accept**.  It's on your unit, on the Lovense feature's *Hive Commands* page, and in the app's [Remote](remote.md) tab, under *Toys*, *From others*, with the list of who's sent you commands:

- **Ask**, to start with: only people you've allowed.  The first time someone sends you a command, they're added to your unit's list, **not allowed**, and the command is ignored.  Allow them, and their commands work from then on.
- **Accept**: anyone's commands work, allowed or not.  New people are still added to the list, so you can see who's been sending, and allow them for when you go back to Ask.
- **Off**: everyone's commands are ignored, and nobody's added.
- **STOP** on your own unit, or in your Remote tab, stops whatever anyone's set.

Two more choices, under it (on the unit, on the page after *Hive Commands*), ignore some commands whoever they're from, allowed or not:

- **Ignore broadcasts**: those sent to everyone who can hear the sender, from their *Broadcast*.  Those sent to the channel over the open direct channel count too, as anyone nearby can hear that.
- **Ignore channel-wide**: those sent to a whole channel, server or direct.

So with both on, only commands sent to you alone get through.  Someone you've [muted](text.md#what-a-conversation-shows) is ignored too.

It's a separate list from the one for [your display](text.md#who-can-put-words-on-your-display), so someone can put words on your display without being allowed near your toys.  Texting you needs neither.  Names can be borrowed on the open channel or an open server, so only allow people on those if you trust everyone there: see [Commands from others](../features/lovense.md#commands-from-others) for the details.
