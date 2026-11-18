#ifndef RCAT_SEAL_TEST_H
#define RCAT_SEAL_TEST_H

#include <stdbool.h>

/* The seal test: checks a speaker housing was put together well enough for
 * the voice effects to go loud without feeding back.
 *
 * It listens to the room for a few seconds, plays a test noise through the
 * speaker and measures how much of it reaches the microphones (the leak) and
 * how much is left after echo cancelling, then asks the wearer to say "aaah"
 * and compares the two microphones. Each is graded against a well sealed
 * housing (SEAL_REF_* in seal_test.c), and the worst problem found picks the
 * advice. The build guide's First Start explains each piece of advice.
 *
 * Only on boards that measure the speaker's own signal alongside the
 * microphones (rcat_hal_audio_levels). */

typedef enum
{
    SEAL_IDLE,
    SEAL_QUIET,     // listening to the room
    SEAL_NOISE,     // playing the test noise
    SEAL_VOICE,     // listening for "aaah"
    SEAL_DONE,
} seal_phase_t;

typedef enum
{
    SEAL_GOOD,
    SEAL_FAIR,      // works, but not as well as a good build
    SEAL_CHECK,     // something's wrong: see the advice
    SEAL_SKIPPED,   // couldn't be measured
} seal_grade_t;

typedef struct
{
    float room_db;          // the room, in the microphones, dB of full scale
    float leak_db;          // the speaker in the microphones, against its own signal
    float cancelled_db;     // what's left of it after echo cancelling
    float balance_db;       // microphone 1 against microphone 2, on the voice
    seal_grade_t leak, cancelled, balance;
    const char *advice;     // a short line for the screen
} seal_result_t;

bool seal_test_available(void);

/* Start the test, stopping the sound player and the voice effect's speaker
 * while it runs. */
void seal_test_start(void);

/* Stop it early, putting the speaker back as it was. */
void seal_test_cancel(void);

/* Call once a second, from the UI loop (the Voice feature does). Returns the
 * phase, and the seconds left in it. */
seal_phase_t seal_test_tick(int *seconds_left);

seal_phase_t seal_test_phase(void);
int seal_test_seconds_left(void);

/* The last result, once the phase is SEAL_DONE */
const seal_result_t *seal_test_result(void);

const char *seal_test_grade_name(seal_grade_t grade);

#endif
