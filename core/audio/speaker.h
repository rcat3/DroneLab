#ifndef RCAT_SPEAKER_H
#define RCAT_SPEAKER_H

#include <stdbool.h>
#include <stdint.h>

/* The speaker, shared by the sound player and the voice effect. While the
 * voice effect is switched to the speaker, it has the speaker and the player
 * waits. Returns false if the board has no speaker. Safe to call more than
 * once. */
bool speaker_start(void);

/* Silence the speaker, whatever it's playing, or let it play again. It
 * fades over a few ms, so it doesn't click. Playing carries on underneath.
 * The comm channel uses it to keep quiet while it sends. Call it from any
 * task. */
void speaker_set_muted(bool muted);

/* A short beep, for lining recordings up with video (see voice_lab.h). It
 * plays over whatever the speaker is playing, after SPEAKER_BEEP_LEAD_MS of
 * silence so the amplifier is on in time. Call it from any task. */
//
// 2 kHz, where the small speaker is louder than at 1 kHz, for long enough
// to hear as a tone and not a click, faded in and out over a few ms so its
// edges don't click either. It's still sharp enough to line up to a frame.
#define SPEAKER_BEEP_HZ         2000
#define SPEAKER_BEEP_MS         300
#define SPEAKER_BEEP_FADE_MS    5
#define SPEAKER_BEEP_LEAD_MS    30
#define SPEAKER_BEEP_LEVEL      0.6f    // of full scale
void speaker_beep(void);

/* The beep's envelope, 0 to 1, at a sample pos after it starts, so that
 * the speaker and the streams make the same beep. */
static inline float speaker_beep_envelope(uint32_t pos, uint32_t sample_rate)
{
    uint32_t fade = sample_rate * SPEAKER_BEEP_FADE_MS / 1000;
    uint32_t len = sample_rate * SPEAKER_BEEP_MS / 1000;
    if (pos >= len)
    {
        return 0.0f;
    }
    uint32_t edge = pos < len - pos ? pos : len - pos;
    return edge >= fade ? 1.0f : (float)edge / fade;
}

/* How many beeps have started to sound, counted by the speaker's task as the
 * tone begins, so a stream can mark the same moment. */
uint32_t speaker_beep_count(void);

#endif
