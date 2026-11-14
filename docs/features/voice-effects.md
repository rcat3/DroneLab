# Voice Effects

*The ESP32-S3-Touch-AMOLED-1.75*

The *Voice Effect* page, in the Voice feature, runs your voice through an effect on the board itself:

| Preset | Sound |
|---|---|
| Natural | Your own voice, like a mask's voice amplifier, with just the boom below it and the hiss above it taken out |
| Female | Your own voice, raised in pitch to around 180 Hz, with the vowels raised less, kept to the middle of the voice's range |
| Fembot | Female, snapped to musical notes, with a faint metallic ring, a little digital grit and a flanger |
| Synthetic | Snapped pitch, a faint metallic ring and slight digital grit |
| Android | A monotone female robot |
| AI | Thinner, higher and snapped, with a quick shimmer |
| Robot | A monotone robot at a low pitch |
| Deep | Your voice, lower |
| Dalek | Higher, thinner and harsh, ring modulated at 30 Hz like the Daleks in Doctor Who |
| Drone | Lower, ring modulated and slightly crushed |

The effect goes to the [Voice Lab](voice-lab.md) stream (`voice_monitor.py --listen effect` plays it) and, with *Play on speaker* switched on, to the board's speaker.  While it's on the speaker, the [sound player](sound.md) waits.

The *Effect Volume* page, next to it, sets how loud the effect is on the speaker, separately from the sound player's volume.  50% is about 10 dB louder than the microphone picks it up, and 100% about 35 dB, with a limiter that rounds off the peaks.  Each preset is set a little louder or quieter on the speaker than that, so that they all start to feed back at about the same setting: just above 100% on the ESP32-S3-Touch-AMOLED-1.75 in its housing.  On that board, every preset holds at 100% even with a mirror held in front of the mask.  Somewhere that reflects more of the sound back, like a corner, brings it down.  If it feeds back, turn it down.

The board's **BOOT** button switches *Play on speaker* off and on, to stop feedback quickly.  (BOOT only matters at startup: held while the board starts, it waits for new firmware over USB.)  The [Phone Remote](phone-remote.md) has all of these too, with the volume in exact steps.

*Play on speaker* is always off at startup, in case it feeds back.  The speaker in the board's housing faces away from the mask, but some of it still reaches the microphones.  The board cancels most of that, because its audio chip hears what the speaker is playing (see its [board notes](../hardware/waveshare_esp32s3_touch_amoled_1_75.md#board-notes)), so it can go much louder before it feeds back.

The ESP32-S3-Touch-LCD-1.46 doesn't have voice effects.  Its built-in speaker faces into the mask, and it can't cancel the speaker out of its microphone, so it would feed back long before the effect was loud enough to hear.

The presets are the same as the effects in `tools/voice_monitor.py`, so they can be tried and tuned on a computer first.  The pitch-following presets add about 15-20 ms of delay, the others less.

Expect Natural to feed back at a lower volume than the others: the effects that change the pitch or ring modulate move the sound off the frequencies that feed back, and Natural doesn't.
