/*
 * The seal test (see seal_test.h).
 */
#include <math.h>
#include <stdio.h>
#include <string.h>

#include "audio/audio_player.h"
#include "audio/mic.h"
#include "audio/seal_test.h"
#include "audio/speaker.h"
#include "audio/voice_fx.h"
#include "hal.h"

// How long each phase lasts, in seconds. The first second of each is thrown
// away, for the sound before it to die down and, while the noise plays, for
// the echo canceller to settle.
#define QUIET_S         3
#define NOISE_S         10
#define NOISE_SETTLE_S  2
#define VOICE_S         5

// The full test: the noise five times, with a second's silence between, so
// the echo canceller has to catch it again each time, then each band, then
// loud
#define REPEATS         5
#define REPEAT_FIRST_S  5
#define REPEAT_S        4
#define REPEAT_GAP_S    1
#define BAND_S          3
#define LOUD_S          4
#define NOISE_LEVEL     0.1f    // RMS, of full scale: -20 dBFS
#define LOUD_LEVEL      0.4f    // -8 dBFS, about as loud as the voice effect plays at full volume
static const float band_hz[SEAL_BAND_COUNT] = { 250, 354, 500, 707, 1000, 1414, 2000, 2828, 4000, 5657 };

// The feedback check: Natural, a dB louder every half second, from
// SEAL_FEEDBACK_START_DB to SEAL_FEEDBACK_TOP_DB over full volume. It counts
// as feeding back once the speaker's this much louder than it was at the
// start, more than the steps up account for (or once voice_fx stops it).
#define FEEDBACK_STEP_DB    1.0f
#define FEEDBACK_STEP_TICKS 5
#define FEEDBACK_RISE_DB    12.0f
#define FEEDBACK_RISE_TICKS 3       // for this long: a knock or a voice in the room is shorter

// The spare: how far over full volume Natural can go before it feeds back.
// On the unsealed housing the feedback check fed back at +13 to +16 dB, and
// the bands said +12 dB.
#define SPARE_GOOD_DB       6.0f
#define SPARE_FAIR_DB       0.0f
// The quick test only has the whole noise, which averages the bands: this
// much is taken off for the band that'll feed back first. On the unsealed
// housing the whole noise came within 1.2 dB of the worst band.
#define BROADBAND_PEAK_DB   3.0f
#define BROADBAND_HZ        1000.0f     // where Natural's gain is taken, for the whole noise

// A good build, measured with this test's noise on the first two speaker
// models built, which were sealed inside with plasticine (the same board
// read the same without it: docs/build/seal-test.md), with the mask worn,
// as it is for the voice check: the leak was +1.3 to +2.1 dB
// and +3.3 dB, and after echo cancelling -21.2 to -21.4 dB and -22.3 dB. On
// a desk, the leak was about 1.5 dB higher (the face takes in some of the
// sound), and what's left after echo cancelling about the same.
#define SEAL_REF_LEAK_DB        2.5f
#define SEAL_REF_CANCELLED_DB   -21.8f

// How far worse than that is still good, and still fair
#define LEAK_GOOD_DB        2.5f
#define LEAK_FAIR_DB        5.0f
#define CANCELLED_GOOD_DB   3.0f
#define CANCELLED_FAIR_DB   6.0f
// Far quieter than a good build: the speaker can't be connected
#define LEAK_MISSING_DB     -15.0f
// Loud against quiet, after echo cancelling: more left loud is a rattle, or
// the speaker distorting, which the echo canceller can't take out
#define LOUD_GOOD_DB        3.0f
#define LOUD_FAIR_DB        6.0f

// The two microphones on the voice, worn: within 1.2 to 2.1 dB of each
// other, with both or neither sealed to the board with foam, and with only
// one sealed, 5.1 dB apart
#define BALANCE_GOOD_DB     3.0f
#define BALANCE_FAIR_DB     4.0f

// The voice has to be this far above the room to count
#define VOICE_ABOVE_ROOM_DB 15.0f
// While the noise plays, the microphones have to hear this much more than
// the room, or the room's what's being measured
#define NOISE_ABOVE_ROOM_DB 10.0f

#define TICKS_PER_S (1000 / SEAL_TICK_MS)

typedef enum
{
    STEP_QUIET,
    STEP_NOISE,     // a repeat
    STEP_GAP,
    STEP_BAND,
    STEP_LOUD,
    STEP_VOICE,
    STEP_FEEDBACK,
} step_kind_t;

typedef struct
{
    step_kind_t kind;
    int seconds;
    int settle;     // seconds thrown away at the start
    int index;      // the repeat, or the band
} step_t;

#define MAX_STEPS   (2 + 2 * REPEATS + SEAL_BAND_COUNT + 2)
#define MAX_WINDOWS 12

static step_t steps[MAX_STEPS];
static int step_count;
static int step;                // the one running, or step_count once done
static seal_phase_t phase;
static int ticks;               // into the step
static int left;                // seconds left in the phase
static float windows_a[MAX_WINDOWS], windows_b[MAX_WINDOWS], windows_c[MAX_WINDOWS], windows_d[MAX_WINDOWS];
static int windows;
static float repeat_leak[REPEATS], repeat_cancelled[REPEATS], repeat_loop[REPEATS];
static bool noisy;
static seal_result_t result;
static bool had_speaker, had_player;
static float feedback_gain, feedback_base;
static int feedback_rising;
static char advice[64];

static float db(float power)
{
    return 10.0f * log10f(power + 1e-12f);
}

static float median(float *v, int n)
{
    // Insertion sort: there are only a few
    for (int i = 1; i < n; i++)
    {
        float x = v[i];
        int j = i - 1;
        for (; j >= 0 && v[j] > x; j--)
        {
            v[j + 1] = v[j];
        }
        v[j + 1] = x;
    }
    return n == 0 ? NAN : n % 2 ? v[n / 2] : (v[n / 2 - 1] + v[n / 2]) / 2;
}

static seal_grade_t grade(float worse_by, float good, float fair)
{
    return worse_by <= good ? SEAL_GOOD : worse_by <= fair ? SEAL_FAIR : SEAL_CHECK;
}

static seal_phase_t phase_of(step_kind_t kind)
{
    switch (kind)
    {
    case STEP_QUIET:
        return SEAL_QUIET;
    case STEP_NOISE:
    case STEP_GAP:
        return SEAL_NOISE;
    case STEP_BAND:
        return SEAL_BANDS;
    case STEP_LOUD:
        return SEAL_LOUD;
    case STEP_VOICE:
        return SEAL_VOICE;
    default:
        return SEAL_FEEDBACK;
    }
}

bool seal_test_available(void)
{
    static int available = -1;
    if (available < 0)
    {
        rcat_hal_audio_levels_t levels;
        available = mic_start() && speaker_start() && rcat_hal_audio_levels(&levels);
    }
    return available;
}

static void restore(void)
{
    speaker_set_test_noise(false);
    speaker_set_test_noise_shape(0, NOISE_LEVEL);
    voice_fx_feedback_test(false);
    voice_fx_set_speaker(had_speaker);
    if (had_player)
    {
        audio_player_resume();
    }
    had_speaker = had_player = false;
}

static void add(step_kind_t kind, int seconds, int settle, int index)
{
    steps[step_count++] = (step_t){ kind, seconds, settle, index };
}

/* Set the speaker up for the step that's starting */
static void begin_step(void)
{
    ticks = 0;
    windows = 0;
    if (step >= step_count)
    {
        return;
    }
    const step_t *s = &steps[step];
    phase = phase_of(s->kind);
    switch (s->kind)
    {
    case STEP_NOISE:
        speaker_set_test_noise_shape(0, NOISE_LEVEL);
        speaker_set_test_noise(true);
        break;
    case STEP_BAND:
        speaker_set_test_noise_shape(band_hz[s->index], NOISE_LEVEL);
        speaker_set_test_noise(true);
        break;
    case STEP_LOUD:
        speaker_set_test_noise_shape(0, LOUD_LEVEL);
        speaker_set_test_noise(true);
        break;
    case STEP_VOICE:
        speaker_set_test_noise(false);
        // The wearer can't see the screen, so a beep says when to speak
        speaker_beep();
        break;
    case STEP_FEEDBACK:
        feedback_gain = SEAL_FEEDBACK_START_DB;
        feedback_base = NAN;
        feedback_rising = 0;
        voice_fx_feedback_test(true);
        voice_fx_feedback_test_gain(feedback_gain);
        voice_fx_set_speaker(true);
        break;
    default:
        speaker_set_test_noise(false);
        break;
    }
    speaker_take_test_noise_level();    // measure what's played from now
}

void seal_test_start(seal_mode_t mode)
{
    if (phase != SEAL_IDLE && phase != SEAL_DONE)
    {
        return;
    }
    had_speaker = voice_fx_speaker_on();
    had_player = audio_player_is_playing();
    voice_fx_set_speaker(false);
    audio_player_pause();
    memset(&result, 0, sizeof(result));
    result.mode = mode;
    result.worst_band = -1;
    result.feedback_db = NAN;
    result.balance_db = NAN;

    step_count = 0;
    switch (mode)
    {
    case SEAL_TEST_FEEDBACK:
    {
        int count = (int)((SEAL_FEEDBACK_TOP_DB - SEAL_FEEDBACK_START_DB) / FEEDBACK_STEP_DB) + 1;
        add(STEP_FEEDBACK, (count * FEEDBACK_STEP_TICKS + TICKS_PER_S - 1) / TICKS_PER_S, 0, 0);
        break;
    }
    case SEAL_TEST_FULL:
        add(STEP_QUIET, QUIET_S, 1, 0);
        for (int i = 0; i < REPEATS; i++)
        {
            if (i > 0)
            {
                add(STEP_GAP, REPEAT_GAP_S, 0, 0);
            }
            add(STEP_NOISE, i == 0 ? REPEAT_FIRST_S : REPEAT_S, i == 0 ? NOISE_SETTLE_S : 1, i);
        }
        for (int i = 0; i < SEAL_BAND_COUNT; i++)
        {
            add(STEP_BAND, BAND_S, 1, i);
        }
        add(STEP_LOUD, LOUD_S, 1, 0);
        add(STEP_VOICE, VOICE_S, 1, 0);
        break;
    default:
        add(STEP_QUIET, QUIET_S, 1, 0);
        add(STEP_NOISE, NOISE_S, NOISE_SETTLE_S, 0);
        add(STEP_VOICE, VOICE_S, 1, 0);
        break;
    }
    noisy = false;
    rcat_hal_audio_levels_t levels;
    rcat_hal_audio_levels(&levels);        // start measuring from now
    step = 0;
    begin_step();
}

void seal_test_cancel(void)
{
    if (phase != SEAL_IDLE && phase != SEAL_DONE)
    {
        restore();
        phase = SEAL_IDLE;
    }
}

static void print_result(void)
{
    const seal_result_t *r = &result;
    if (r->mode == SEAL_TEST_FEEDBACK)
    {
        if (isnan(r->feedback_db))
        {
            printf("seal test: feedback check: none up to %+.0f dB over full volume\n", SEAL_FEEDBACK_TOP_DB);
        }
        else
        {
            printf("seal test: feedback check: fed back at %+.0f dB over full volume\n", r->feedback_db);
        }
        return;
    }
    printf("seal test: room %.1f dB, leak %+.1f dB (%s), after echo cancelling %+.1f dB (%s), "
           "microphones %+.1f dB (%s), spare %+.1f dB (%s)\n",
           r->room_db, r->leak_db, seal_test_grade_name(r->leak), r->cancelled_db,
           seal_test_grade_name(r->cancelled), r->balance_db, seal_test_grade_name(r->balance), r->spare_db,
           seal_test_grade_name(r->spare));
    if (r->mode != SEAL_TEST_FULL || r->leak == SEAL_SKIPPED)
    {
        return;
    }
    printf("seal test: %d repeats: leak %+.1f to %+.1f dB, after echo cancelling %+.1f to %+.1f dB\n", r->repeats,
           r->leak_min, r->leak_max, r->cancelled_min, r->cancelled_max);
    printf("seal test: loud: leak %+.1f dB, after echo cancelling %+.1f dB (%s)\n", r->loud_leak_db,
           r->loud_cancelled_db, seal_test_grade_name(r->loud));
    for (int i = 0; i < SEAL_BAND_COUNT; i++)
    {
        const seal_band_t *b = &r->bands[i];
        printf("seal test: band %4.0f Hz: leak %+5.1f dB, after echo cancelling %+5.1f dB, spare %+5.1f dB%s%s\n",
               b->hz, b->leak_db, b->cancelled_db, b->spare_db, b->noisy ? " (too noisy)" : "",
               i == r->worst_band ? " <- feeds back first" : "");
    }
    if (r->worst_band >= 0)
    {
        printf("seal test: Natural should feed back first at %.0f Hz, %+.1f dB over full volume "
               "(the quick test would say %+.1f dB)\n",
               r->bands[r->worst_band].hz, r->spare_db, r->broadband_spare_db);
    }
}

static void finish(void)
{
    seal_result_t *r = &result;
    if (r->mode == SEAL_TEST_FEEDBACK)
    {
        r->leak = r->cancelled = r->balance = r->loud = r->spare = SEAL_SKIPPED;
        if (isnan(r->feedback_db))
        {
            snprintf(advice, sizeof(advice), "No feedback up to\n%+.0f dB over full volume.", SEAL_FEEDBACK_TOP_DB);
        }
        else if (r->feedback_db >= 0)
        {
            snprintf(advice, sizeof(advice), "Fed back at %+.0f dB\nover full volume.", r->feedback_db);
        }
        else
        {
            // Effect Volume steps are half a dB
            snprintf(advice, sizeof(advice), "Fed back at %.0f%%\nEffect Volume.", 100.0f + r->feedback_db * 2.0f);
        }
        r->advice = advice;
        print_result();
        return;
    }

    if (r->repeats > 0)
    {
        float l[REPEATS], c[REPEATS], g[REPEATS];
        memcpy(l, repeat_leak, sizeof(l));
        memcpy(c, repeat_cancelled, sizeof(c));
        memcpy(g, repeat_loop, sizeof(g));
        r->leak_db = median(l, r->repeats);
        r->cancelled_db = median(c, r->repeats);
        r->broadband_spare_db = -(median(g, r->repeats) + voice_fx_natural_full_db(BROADBAND_HZ)) - BROADBAND_PEAK_DB;
        r->leak_min = l[0];
        r->leak_max = l[r->repeats - 1];
        r->cancelled_min = c[0];
        r->cancelled_max = c[r->repeats - 1];
    }
    if (noisy)
    {
        r->leak = SEAL_SKIPPED;
    }

    float leak_worse = r->leak_db - SEAL_REF_LEAK_DB;
    bool missing = !noisy && leak_worse < LEAK_MISSING_DB;
    if (!noisy)
    {
        r->leak = missing ? SEAL_CHECK : grade(leak_worse, LEAK_GOOD_DB, LEAK_FAIR_DB);
        r->cancelled = grade(r->cancelled_db - SEAL_REF_CANCELLED_DB, CANCELLED_GOOD_DB, CANCELLED_FAIR_DB);
        r->loud = r->mode == SEAL_TEST_FULL ? grade(r->loud_cancelled_db - r->cancelled_db, LOUD_GOOD_DB, LOUD_FAIR_DB)
                                            : SEAL_SKIPPED;
        if (r->worst_band < 0)
        {
            r->spare_db = r->broadband_spare_db;
        }
        r->spare = grade(-r->spare_db, -SPARE_GOOD_DB, -SPARE_FAIR_DB);
    }
    else
    {
        r->cancelled = r->loud = r->spare = SEAL_SKIPPED;
    }
    if (isnan(r->balance_db))
    {
        r->balance = SEAL_SKIPPED;
    }
    else
    {
        r->balance = grade(fabsf(r->balance_db), BALANCE_GOOD_DB, BALANCE_FAIR_DB);
    }

    // The worst problem picks the advice
    if (noisy)
    {
        r->advice = "Too noisy here.\nTry again somewhere quieter.";
    }
    else if (missing)
    {
        r->advice = "The microphones barely hear\nthe speaker. Is it plugged in?";
    }
    else if (r->spare == SEAL_CHECK)
    {
        // Feeds back below full volume: say what's most likely why
        r->advice = r->loud == SEAL_CHECK   ? "Feeds back below full volume.\nCheck the screws and battery."
                    : r->leak == SEAL_CHECK ? "Feeds back below full volume.\nCheck the speaker and chin."
                                            : "Feeds back below full volume.\nSee the build guide.";
    }
    else if (r->loud == SEAL_CHECK)
    {
        r->advice = "Something rattles when loud.\nCheck the screws and battery.";
    }
    else if (r->balance == SEAL_CHECK)
    {
        r->advice = "The microphones don't match.\nCheck foam wind screen\nin mic chamber.";
    }
    else if (r->spare == SEAL_FAIR || r->balance == SEAL_FAIR || r->loud == SEAL_FAIR)
    {
        r->advice = "Works, but could be better.\nSee the build guide.";
    }
    else if (r->balance == SEAL_SKIPPED)
    {
        r->advice = "All good. No voice heard,\nso the microphones weren't checked.";
    }
    else
    {
        r->advice = "All good.";
    }
    print_result();
}

/* A step's done: keep what it measured */
static void end_step(void)
{
    const step_t *s = &steps[step];
    seal_result_t *r = &result;
    switch (s->kind)
    {
    case STEP_QUIET:
        r->room_db = median(windows_a, windows);
        break;
    case STEP_NOISE:
        repeat_leak[r->repeats] = median(windows_a, windows);
        repeat_cancelled[r->repeats] = median(windows_b, windows);
        repeat_loop[r->repeats] = median(windows_d, windows);
        r->repeats++;
        noisy |= median(windows_c, windows) < r->room_db + NOISE_ABOVE_ROOM_DB;
        break;
    case STEP_BAND:
    {
        seal_band_t *b = &r->bands[s->index];
        b->hz = band_hz[s->index];
        b->leak_db = median(windows_a, windows);
        b->cancelled_db = median(windows_b, windows);
        b->noisy = median(windows_c, windows) < r->room_db + NOISE_ABOVE_ROOM_DB;
        // Round the loop: what's left after echo cancelling against what
        // was played, then Natural's gain at full volume back to the speaker
        b->spare_db = -(median(windows_d, windows) + voice_fx_natural_full_db(b->hz));
        if (!b->noisy && (r->worst_band < 0 || b->spare_db < r->spare_db))
        {
            r->worst_band = s->index;
            r->spare_db = b->spare_db;
        }
        break;
    }
    case STEP_LOUD:
        r->loud_leak_db = median(windows_a, windows);
        r->loud_cancelled_db = median(windows_b, windows);
        break;
    case STEP_VOICE:
        if (windows > 0)
        {
            r->balance_db = median(windows_a, windows);
        }
        break;
    default:
        break;
    }
}

/* A second's levels, for the step running */
static void measure(const rcat_hal_audio_levels_t *l)
{
    const step_t *s = &steps[step];
    int second = ticks / TICKS_PER_S;      // 1 for the first
    float played = speaker_take_test_noise_level();
    if (second <= s->settle || windows >= MAX_WINDOWS)
    {
        return;
    }
    switch (s->kind)
    {
    case STEP_QUIET:
        windows_a[windows++] = db(l->mics);
        break;
    case STEP_NOISE:
    case STEP_BAND:
    case STEP_LOUD:
        windows_a[windows] = db(l->mics) - db(l->speaker);
        windows_b[windows] = db(l->cancelled) - db(l->speaker);
        windows_c[windows] = db(l->mics);
        windows_d[windows] = db(l->cancelled) - db(played);
        windows++;
        break;
    case STEP_VOICE:
        if (db(l->mics) > result.room_db + VOICE_ABOVE_ROOM_DB)
        {
            windows_a[windows++] = db(l->mic1) - db(l->mic2);
        }
        break;
    default:
        break;
    }
}

/* A tick of the feedback check. Returns true once it's done. */
static bool feedback_tick(void)
{
    float level = db(voice_fx_feedback_take_level());
    int at = ticks % FEEDBACK_STEP_TICKS;
    bool fed_back = voice_fx_feedback_tripped();
    if (!isnan(feedback_base))
    {
        bool rising = level > feedback_base + (feedback_gain - SEAL_FEEDBACK_START_DB) + FEEDBACK_RISE_DB;
        feedback_rising = rising ? feedback_rising + 1 : 0;
        fed_back |= feedback_rising >= FEEDBACK_RISE_TICKS;
    }
    else if (at == FEEDBACK_STEP_TICKS - 1)
    {
        feedback_base = level;      // the first step's last tick: the hiss, before it's any louder
    }
    if (fed_back)
    {
        voice_fx_feedback_test_gain(-100.0f);
        result.feedback_db = feedback_gain;
        return true;
    }
    if (at == FEEDBACK_STEP_TICKS - 1)
    {
        feedback_gain += FEEDBACK_STEP_DB;
        if (feedback_gain > SEAL_FEEDBACK_TOP_DB)
        {
            return true;
        }
        voice_fx_feedback_test_gain(feedback_gain);
    }
    return false;
}

static int seconds_left_in_phase(void)
{
    if (step >= step_count)
    {
        return 0;
    }
    int total = 0;
    for (int i = step; i < step_count && phase_of(steps[i].kind) == phase; i++)
    {
        total += steps[i].seconds * TICKS_PER_S;
    }
    total -= ticks;
    if (phase == SEAL_FEEDBACK)
    {
        float steps_left = (SEAL_FEEDBACK_TOP_DB - feedback_gain) / FEEDBACK_STEP_DB + 1;
        total = (int)steps_left * FEEDBACK_STEP_TICKS - ticks % FEEDBACK_STEP_TICKS;
    }
    return total > 0 ? (total + TICKS_PER_S - 1) / TICKS_PER_S : 0;
}

seal_phase_t seal_test_tick(int *seconds_left)
{
    if (phase == SEAL_IDLE || phase == SEAL_DONE)
    {
        left = 0;
        if (seconds_left != NULL)
        {
            *seconds_left = 0;
        }
        return phase;
    }
    ticks++;
    bool done;
    if (steps[step].kind == STEP_FEEDBACK)
    {
        done = feedback_tick();
    }
    else
    {
        if (ticks % TICKS_PER_S == 0)
        {
            rcat_hal_audio_levels_t l;
            if (rcat_hal_audio_levels(&l) && l.samples > 0)
            {
                measure(&l);
            }
        }
        done = ticks >= steps[step].seconds * TICKS_PER_S;
    }
    if (done)
    {
        end_step();
        step++;
        if (step >= step_count)
        {
            restore();
            finish();
            phase = SEAL_DONE;
        }
        else
        {
            begin_step();
        }
    }
    left = phase == SEAL_DONE ? 0 : seconds_left_in_phase();
    if (seconds_left != NULL)
    {
        *seconds_left = left;
    }
    return phase;
}

seal_phase_t seal_test_phase(void)
{
    return phase;
}

int seal_test_seconds_left(void)
{
    return left;
}

float seal_test_feedback_gain_db(void)
{
    return feedback_gain;
}

const seal_result_t *seal_test_result(void)
{
    return &result;
}

const char *seal_test_grade_name(seal_grade_t g)
{
    switch (g)
    {
    case SEAL_GOOD:
        return "good";
    case SEAL_FAIR:
        return "fair";
    case SEAL_CHECK:
        return "check";
    default:
        return "skipped";
    }
}

const char *seal_test_mode_name(seal_mode_t mode)
{
    switch (mode)
    {
    case SEAL_TEST_FULL:
        return "Full test";
    case SEAL_TEST_FEEDBACK:
        return "Feedback check";
    default:
        return "Quick test";
    }
}
