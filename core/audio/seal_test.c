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

// A well sealed housing, measured with this test's noise on the first two
// speaker models built, with plasticine behind the speaker, around its wire
// and around the chamber, and open-cell foam in the microphones' cell, with
// the mask worn, as it is for the voice check: the leak was +1.3 to +2.1 dB
// and +3.3 dB, and after echo cancelling -21.2 to -21.4 dB and -22.3 dB. On
// a desk, the leak was about 1.5 dB higher (the face takes in some of the
// sound), and what's left after echo cancelling about the same.
#define SEAL_REF_LEAK_DB        2.5f
#define SEAL_REF_CANCELLED_DB   -21.8f

// How far worse than that is still good, and still fair. A housing with no
// plasticine leaked about 4 dB more, and after echo cancelling about 10 dB
// more, which is what matters for feedback.
#define LEAK_GOOD_DB        2.5f
#define LEAK_FAIR_DB        5.0f
#define CANCELLED_GOOD_DB   3.0f
#define CANCELLED_FAIR_DB   6.0f
// Far quieter than a good build: the speaker can't be connected
#define LEAK_MISSING_DB     -15.0f

// The two microphones on the voice, worn: with both sealed to the board with
// foam they heard it within 1.8 dB of each other, and with one left unsealed,
// 5.1 dB apart
#define BALANCE_GOOD_DB     3.0f
#define BALANCE_FAIR_DB     4.0f

// The voice has to be this far above the room to count
#define VOICE_ABOVE_ROOM_DB 15.0f
// While the noise plays, the microphones have to hear this much more than
// the room, or the room's what's being measured
#define NOISE_ABOVE_ROOM_DB 10.0f

#define MAX_WINDOWS 12

static seal_phase_t phase;
static int elapsed;             // seconds into the phase
static int left;                // and left in it
static float windows_a[MAX_WINDOWS], windows_b[MAX_WINDOWS], windows_c[MAX_WINDOWS];
static int windows;
static seal_result_t result;
static bool had_speaker, had_player;

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
    if (had_speaker)
    {
        voice_fx_set_speaker(true);
    }
    if (had_player)
    {
        audio_player_resume();
    }
    had_speaker = had_player = false;
}

static void begin(seal_phase_t p)
{
    phase = p;
    elapsed = 0;
    windows = 0;
}

void seal_test_start(void)
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
    rcat_hal_audio_levels_t levels;
    rcat_hal_audio_levels(&levels);        // start measuring from now
    begin(SEAL_QUIET);
}

void seal_test_cancel(void)
{
    if (phase != SEAL_IDLE && phase != SEAL_DONE)
    {
        restore();
        phase = SEAL_IDLE;
    }
}

static void finish(void)
{
    seal_result_t *r = &result;
    float leak_worse = r->leak_db - SEAL_REF_LEAK_DB;
    bool noisy = r->leak == SEAL_SKIPPED;
    bool missing = !noisy && leak_worse < LEAK_MISSING_DB;
    if (!noisy)
    {
        r->leak = missing ? SEAL_CHECK : grade(leak_worse, LEAK_GOOD_DB, LEAK_FAIR_DB);
        r->cancelled = grade(r->cancelled_db - SEAL_REF_CANCELLED_DB, CANCELLED_GOOD_DB, CANCELLED_FAIR_DB);
    }
    else
    {
        r->cancelled = SEAL_SKIPPED;
    }
    if (r->balance != SEAL_SKIPPED)
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
    else if (r->leak == SEAL_CHECK)
    {
        r->advice = "The speaker leaks in.\nCheck the plasticine.";
    }
    else if (r->cancelled == SEAL_CHECK)
    {
        r->advice = "Something rattles.\nCheck the screws and battery.";
    }
    else if (r->balance == SEAL_CHECK)
    {
        r->advice = "The microphones don't match.\nCheck their foam squares.";
    }
    else if (r->leak == SEAL_FAIR || r->cancelled == SEAL_FAIR || r->balance == SEAL_FAIR)
    {
        r->advice = "Works, but could be better.\nSee the build guide.";
    }
    else if (r->balance == SEAL_SKIPPED)
    {
        r->advice = "Sealed well. No voice heard,\nso the microphones weren't checked.";
    }
    else
    {
        r->advice = "Sealed well.";
    }
    printf("seal test: room %.1f dB, leak %+.1f dB (%s), after echo cancelling %+.1f dB (%s), "
           "microphones %+.1f dB (%s)\n",
           r->room_db, r->leak_db, seal_test_grade_name(r->leak), r->cancelled_db,
           seal_test_grade_name(r->cancelled), r->balance_db, seal_test_grade_name(r->balance));
}

seal_phase_t seal_test_tick(int *seconds_left)
{
    rcat_hal_audio_levels_t l;
    if (phase == SEAL_IDLE || phase == SEAL_DONE || !rcat_hal_audio_levels(&l) || l.samples == 0)
    {
        left = 0;
        if (seconds_left != NULL)
        {
            *seconds_left = 0;
        }
        return phase;
    }
    elapsed++;
    switch (phase)
    {
    case SEAL_QUIET:
        if (elapsed > 1 && windows < MAX_WINDOWS)
        {
            windows_a[windows++] = db(l.mics);
        }
        if (elapsed >= QUIET_S)
        {
            result.room_db = median(windows_a, windows);
            speaker_set_test_noise(true);
            begin(SEAL_NOISE);
        }
        break;

    case SEAL_NOISE:
        if (elapsed > NOISE_SETTLE_S && windows < MAX_WINDOWS)
        {
            windows_a[windows] = db(l.mics) - db(l.speaker);
            windows_b[windows] = db(l.cancelled) - db(l.speaker);
            windows_c[windows] = db(l.mics);
            windows++;
        }
        if (elapsed >= NOISE_S)
        {
            speaker_set_test_noise(false);
            // The wearer can't see the screen, so a beep says when to speak
            speaker_beep();
            result.leak_db = median(windows_a, windows);
            result.cancelled_db = median(windows_b, windows);
            if (median(windows_c, windows) < result.room_db + NOISE_ABOVE_ROOM_DB)
            {
                result.leak = SEAL_SKIPPED;     // finish() takes it as too noisy
            }
            begin(SEAL_VOICE);
        }
        break;

    case SEAL_VOICE:
        if (elapsed > 1 && windows < MAX_WINDOWS && db(l.mics) > result.room_db + VOICE_ABOVE_ROOM_DB)
        {
            windows_a[windows++] = db(l.mic1) - db(l.mic2);
        }
        if (elapsed >= VOICE_S)
        {
            if (windows > 0)
            {
                result.balance_db = median(windows_a, windows);
            }
            else
            {
                result.balance_db = NAN;
                result.balance = SEAL_SKIPPED;
            }
            restore();
            finish();
            phase = SEAL_DONE;
        }
        break;

    default:
        break;
    }
    int total = phase == SEAL_QUIET ? QUIET_S : phase == SEAL_NOISE ? NOISE_S : phase == SEAL_VOICE ? VOICE_S : 0;
    left = total > elapsed ? total - elapsed : 0;
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
