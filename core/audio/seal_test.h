#ifndef RCAT_SEAL_TEST_H
#define RCAT_SEAL_TEST_H

#include <stdbool.h>

/* The seal test: checks a speaker housing was put together well enough for
 * the voice effects to go loud without feeding back.
 *
 * It listens to the room for a few seconds, plays a test noise through the
 * speaker and measures how much of it reaches the microphones (the leak) and
 * how much is left after echo cancelling, then asks the wearer to say "aaah"
 * and compares the two microphones. From what's left after echo cancelling
 * it works out how far over full volume Natural (the preset that feeds back
 * first) can go before it feeds back: the spare, which is what's graded. The
 * leak, graded against a well sealed housing (SEAL_REF_* in seal_test.c),
 * and the loud noise point at what to fix, and the worst problem found picks
 * the advice. The build guide's First Start explains each piece of advice.
 *
 * The full test does the same with the noise played five times, to see how
 * much the result wanders, then one band at a time, to find where it'll feed
 * back first and how far over full volume that is, then loud, to hear
 * rattles the echo canceller can't take out. The feedback check plays
 * Natural, without its gate, louder and louder until it feeds back, and
 * stops as soon as it does.
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
    SEAL_BANDS,     // the full test: the noise one band at a time
    SEAL_LOUD,      // the full test: the noise, loud
    SEAL_FEEDBACK,  // the feedback check
} seal_phase_t;

typedef enum
{
    SEAL_TEST_QUICK,
    SEAL_TEST_FULL,
    SEAL_TEST_FEEDBACK,
    SEAL_TEST_MODES
} seal_mode_t;

typedef enum
{
    SEAL_GOOD,
    SEAL_FAIR,      // works, but not as well as a good build
    SEAL_CHECK,     // something's wrong: see the advice
    SEAL_SKIPPED,   // couldn't be measured
} seal_grade_t;

#define SEAL_BAND_COUNT 10

typedef struct
{
    float hz;
    float leak_db;          // as below, for this band alone
    float cancelled_db;
    float spare_db;         // how far over full volume Natural can go before this band feeds back
    bool noisy;             // the room was too loud to measure it
} seal_band_t;

typedef struct
{
    seal_mode_t mode;
    float room_db;          // the room, in the microphones, dB of full scale
    float leak_db;          // the speaker in the microphones, against its own signal
    float cancelled_db;     // what's left of it after echo cancelling
    float balance_db;       // microphone 1 against microphone 2, on the voice
    seal_grade_t leak, cancelled, balance;     // leak and cancelled against a sealed housing (SEAL_REF_*)
    float spare_db;         // how far over full volume Natural can go before it feeds back:
                            // from the bands in the full test, the whole noise in the quick one
    seal_grade_t spare;
    const char *advice;     // a short line for the screen

    // The full test
    int repeats;            // how many times the noise played (the middle one's above)
    float leak_min, leak_max, cancelled_min, cancelled_max;
    float loud_leak_db, loud_cancelled_db;      // with the noise near full volume
    seal_grade_t loud;      // how much worse echo cancelling does loud
    seal_band_t bands[SEAL_BAND_COUNT];
    int worst_band;         // the one that feeds back first, or -1
    float broadband_spare_db;   // the spare as the quick test works it out, to compare

    // The feedback check: dB over full volume where Natural fed back, or NAN
    // if it didn't by SEAL_FEEDBACK_TOP_DB
    float feedback_db;
} seal_result_t;

#define SEAL_FEEDBACK_START_DB  -10.0f
#define SEAL_FEEDBACK_TOP_DB    20.0f

bool seal_test_available(void);

/* Start the test, stopping the sound player and the voice effect's speaker
 * while it runs. */
void seal_test_start(seal_mode_t mode);

/* Stop it early, putting the speaker back as it was. */
void seal_test_cancel(void);

/* Call every SEAL_TICK_MS, from the UI loop (the Voice feature does). Returns
 * the phase, and the seconds left in it. */
#define SEAL_TICK_MS 100
seal_phase_t seal_test_tick(int *seconds_left);

seal_phase_t seal_test_phase(void);
int seal_test_seconds_left(void);

/* While the feedback check runs: how loud it's playing, in dB over full volume */
float seal_test_feedback_gain_db(void);

/* The last result, once the phase is SEAL_DONE */
const seal_result_t *seal_test_result(void);

const char *seal_test_grade_name(seal_grade_t grade);
const char *seal_test_mode_name(seal_mode_t mode);

#endif
