#ifndef RCAT_SPEAKER_H
#define RCAT_SPEAKER_H

#include <stdbool.h>
#include <stdint.h>

/* The speaker, shared by the sound player and the voice effect. While the
 * voice effect is switched to the speaker, it has the speaker and the player
 * waits. Returns false if the board has no speaker. Safe to call more than
 * once. */
bool speaker_start(void);

/* A short beep, for lining recordings up with video (see voice_lab.h). It
 * plays over whatever the speaker is playing, after SPEAKER_BEEP_LEAD_MS of
 * silence so the amplifier is on in time. Call it from any task. */
#define SPEAKER_BEEP_HZ         1000
#define SPEAKER_BEEP_MS         150
#define SPEAKER_BEEP_LEAD_MS    30
#define SPEAKER_BEEP_LEVEL      0.4f    // of full scale
void speaker_beep(void);

/* How many beeps have started to sound, counted by the speaker's task as the
 * tone begins, so a stream can mark the same moment. */
uint32_t speaker_beep_count(void);

#endif
