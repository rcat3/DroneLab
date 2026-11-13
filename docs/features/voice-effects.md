# Voice Effects

*Boards with a microphone: the ESP32-S3 boards*

The *Voice Effect* page, in the Voice feature, runs your voice through an effect on the board itself:

| Preset | Sound |
|---|---|
| Natural | Your own voice, like a mask's voice amplifier, with just the boom below it and the hiss above it taken out |
| Female | Your own intonation, raised in pitch to around 180 Hz, with the vowels raised less, kept to the middle of the voice's range |
| Fembot | Female, with the pitch snapped to musical notes and a light chorus |
| Synthetic | Snapped pitch, a faint metallic ring and slight digital grit |
| Android | A monotone female robot |
| AI | Thinner, higher and snapped, with a quick shimmer |
| Robot | A monotone robot at a low pitch |
| Deep | Your voice, lower |
| Dalek | Higher, thinner and harsh, ring modulated at 30 Hz like the Daleks in Doctor Who |
| Drone | Lower, ring modulated and slightly crushed |

The effect goes to the [Voice Lab](voice-lab.md) stream (`voice_monitor.py --listen effect` plays it) and, with *Play on speaker* switched on, to the board's speaker.  While it's on the speaker, the [sound player](sound.md) waits.

The *Effect Volume* page, next to it, sets how loud the effect is on the speaker, separately from the sound player's volume.  50% is about 10 dB louder than the microphone picks it up, and 100% about 35 dB, with a limiter that rounds off the peaks.  If it feeds back, turn it down.

*Play on speaker* is always off at startup: with the speaker facing into the mask, it feeds back.  A speaker facing away from the mask works much better, like the ones in the speaker housings (see [Hardware](../../README.md#hardware)).  Even then, some of the speaker reaches the microphones, so too much volume feeds back.  The ESP32-S3-Touch-AMOLED-1.75 cancels most of that, because its audio chip hears what the speaker is playing (see its [board notes](../hardware/waveshare_esp32s3_touch_amoled_1_75.md#board-notes)), so it can go much louder before it does.

The presets are the same as the effects in `tools/voice_monitor.py`, so they can be tried and tuned on a computer first.  The pitch-following presets add about 15-20 ms of delay, the others less.

Expect Natural to feed back at a lower volume than the others: the effects that change the pitch or ring modulate move the sound off the frequencies that feed back, and Natural doesn't.
