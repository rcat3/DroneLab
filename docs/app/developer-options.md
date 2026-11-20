# Developer options

Hidden at first, as Android's are: on the *About* page (Setup, (i) top right), **tap the version ten times**.  The last few taps count down, then **Developer options** shows in Setup, under *Developer*.  Its *Show developer options* switch hides them again, and turns the responders off.

They're for testing direct mode's range and relaying with only one person: leave a unit and its phone at base with a responder on, and take the other unit out.  The phone at base answers as if someone were there, using the app's own ways of talking and texting.

Back to [the app](README.md).

## Voice responder

Each transmission heard on the channel you talk to, server or direct, is recorded and sent back as a transmission of yours, the same way it came, **1 second after it ends**: at most 30 seconds of it, and the recording is discarded once it's sent.  It's the voice as it came, not recorded again, so you hear what the base heard.  Two talking at once are sent back one after the other.

- Not in a call, and not while you're talking yourself.
- Sending back over direct needs unit firmware newer than 0.9.8: the phone hands the unit the voice to send as its own.
- A transmission that starts while one is being sent back, or within 1.5 seconds after, isn't answered, so two responders don't answer each other for ever.

## Text responder

Each text received is **echoed back** to the conversation it came in, on every channel, a second after it comes, the ways a text there goes.  *Echo texts* off leaves only the commands.  A text typed on that phone in the last minute isn't echoed, nor the same text twice within 5 seconds, so two responders don't echo each other for ever.

A text sent to it **privately** that starts with **/** is a command instead, answered privately.  The channel commands are for voice: texts are echoed on every channel anyway.

| Command | Does |
|---|---|
| `/help` | Lists these |
| `/ping` | Answers *pong*, with how your ping came: which ways, sends heard, relays, signal |
| `/status` | The unit, its firmware and battery, the voice channel, the server and its channel, direct's channel and units heard, and the responders |
| `/nearby` | Units heard over direct, strongest first: signal in dBm, how long since, firmware, app, key, talking |
| `/details [N]` | The [details](text.md#message-details) of the last N texts received (5, up to 20), not their words |
| `/talk server` or `/talk direct` | The voice channel talked to, and answered |
| `/channels` | The server's voice channels, with how many are in each |
| `/join <name>` | Move to a server voice channel |
| `/direct` | The direct channels kept on that phone, the one it's on marked |
| `/direct <name>` | Move to one of them; `/direct open` for the open channel |
| `/voice on` or `off` | The voice responder |
| `/echo on` or `off` | Echoing texts |

Moving the base to another direct channel leaves your own unit unable to hear it until you move too: send it while you can still reach it another way, or move yours first.

While the text responder's on, anyone who texts that phone privately can use the commands.

## Over adb

With the phone on USB and developer options shown in the app, the same commands work from a computer, the answer coming back on the broadcast's `data=` line, and in `adb logcat -s flutter`:

```
adb shell am broadcast -a io.github.rcat3.dronelab.DEV -p io.github.rcat3.dronelab -e c "/nearby"
```

`c` is a command as above, or `voice on`/`off`, `text on`/`off`, `echo on`/`off`, or `dev off` to hide the developer options; none says how they are.  Nothing's taken while developer options are hidden, and adb can't show them: only the ten taps can.  Only adb's shell can send it (it needs Android's DUMP permission, which apps can't have), and the app must be running.
