# Sound

*Boards with a speaker: the ESP32-S3 boards*

The Sound feature plays sound files from the SD card.  Its pages are:

- **Player**: the track that's playing, with how far through it is in the middle, and previous, play/pause and next buttons below.  Drag the bar to move through the track; the times either side show where it'll go.  In an MP3, it goes to the same share of the file, which is exact if the bitrate is constant, and close if not.  Sound keeps playing in the background while you look at images or anything else.
- **Options**: the volume, what happens at the end of a track (*Repeat all*, *Repeat one* or *Play once*), and *Play at startup*, which starts playing the last track as soon as the display turns on.

## Sounds on the SD card

1. Make a folder called `sounds` on the card.
2. Copy WAV, MP3 or FLAC files into it.
3. Put the card in the board and switch it on.

The sounds are played in order of file name.  They're read from the card as they play, so they can be any length.  A sound that repeats (*Repeat one*) starts again straight after its end, so short sound effects loop without a gap.  MP3s loop without a gap if the encoder recorded the silence it adds to each end (LAME and ffmpeg do); otherwise there's a short pause at the loop.

Limits:

- Up to 100 sounds are found on the card.
- Any sample rate works.  Mono and stereo files both play, and files with more channels play their first two.
- Files that can't be played are skipped, and the reason is printed in the board's log.
- The card is only read when the board starts, so restart it after changing the card.

While the [Voice Effect](voice-effects.md) is playing on the speaker, the player waits.
