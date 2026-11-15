/*
 * The comm channel (see comm.h).
 *
 * Three tasks share it:
 * - the microphone's task hands in the processed voice (from voice_fx), which
 *   goes into a ring buffer, and listens for speech for voice mode
 * - its own task encodes the voice with Opus and sends it to the phone, as
 *   Opus needs more stack than the microphone's task has
 * - the UI loop switches it on and off, and answers the phone (comm_poll)
 *
 * The ring buffer has one writer and one reader, so it needs no lock: the
 * writer publishes how far it's got with an atomic store.
 */
#include "app/comm.h"

#if RCAT_HAVE_COMM

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "opus.h"

#include "app/remote.h"
#include "app/settings.h"
#include "audio/voice_fx.h"
#include "hal.h"

// 1 to print how long encoding takes, how loud the voice is, and what was
// sent, every few seconds.
#define COMM_DEBUG          0

#define FS                  VOICE_FX_SAMPLE_RATE
#define FRAME               (FS * 20 / 1000)    // samples in an Opus packet
#define RING                16384               // about 1 s; a power of two
#define RING_MASK           (RING - 1)

// The voice effect's output is at the microphone's level, a voice peaking
// around -22 dBFS, which is quiet on headphones, and each effect comes out
// at a different level. So an automatic gain turns it up, while the voice is
// heard, until its loud parts reach AGC_TARGET_DB, between AGC_MIN_DB and
// AGC_MAX_DB. It comes down quickly and goes up slowly, and soft limiting
// rounds off what's left over. It starts at AGC_START_DB.
#define AGC_TARGET_DB       -18.0f  // 20 ms level, before limiting
#define AGC_START_DB        16.0f
#define AGC_MIN_DB          0.0f
#define AGC_MAX_DB          26.0f
#define AGC_UP_DB           0.06f   // per 20 ms frame: 3 dB/s
#define AGC_DOWN_DB         1.0f    // per 20 ms frame, at most

// Opus: speech, 24 kb/s, which sounds good at 16 kHz, and in-band error
// correction for the internet's lost packets. Complexity 3 of 10 keeps it
// quick, for little loss at this rate.
#define OPUS_BITRATE        24000
#define OPUS_COMPLEXITY     3
#define OPUS_LOSS_PERCENT   5
#define MAX_OPUS_BYTES      160
#define HEADER_BYTES        4

#define MSG_SOUND           0x01
#define MSG_STATUS          0x02
#define MSG_TALK            0x01
#define MSG_MODE            0x02
#define FLAG_FIRST          0x01
#define FLAG_LAST           0x02
#define STATUS_SENDING      0x01
#define STATUS_HEARD        0x02
#define STATUS_EVERY_MS     5000

// Voice mode: the voice effect's output is louder than VOX_DB (in dB below
// full scale, before the automatic gain) above 200 Hz, which leaves out most
// rumble, for VOX_ATTACK frames in a row. Every effect starts with a gate at
// -45 dB on the microphone, so between words it's silent but for the gate
// closing, which reached -52 dB in the mask, and speech is around -30 dB. It keeps talking for
// VOX_HANG_MS after the voice stops, so it doesn't cut out between words,
// and starts VOX_PREROLL_MS before it heard the voice, so the start of the
// first word isn't lost.
#define VOX_DB              -46.0f
#define VOX_ATTACK          2
#define VOX_HANG_MS         800
#define VOX_PREROLL_MS      150

// Push to talk carries on this long after it's let go, for the end of the last word.
#define PTT_TAIL_MS         60

// If sending falls this far behind, skip to now.
#define MAX_BEHIND_MS       300

#define TASK_STACK          (32 * 1024)     // Opus puts its working buffers on the stack
#define TASK_IDLE_MS        50
#define TASK_BUSY_MS        5
#define SEND_RETRIES        5
#define SEND_RETRY_MS       2

#define MS_TO_SAMPLES(ms)   ((uint32_t)(ms) * (FS / 1000))

static rcat_hal_ble_peer_service_t service;
static bool available;
static volatile bool running;
static volatile comm_mode_t mode;
static volatile bool screen_talk;
static volatile bool phone_talk;
static volatile bool sending;

// Written by the microphone's task
static int16_t *ring;
static uint32_t ring_write;             // samples written since it started, published atomically
static volatile bool voice_heard;
static volatile uint32_t voice_until;   // ring_write at which voice mode's hang ends
static float hp_x, hp_y;                // the 200 Hz high pass
static float frame_energy;
static float frame_full_energy;         // without the high pass, for the gain
static float agc_db = AGC_START_DB;
static float agc_gain;                  // agc_db as a factor, smoothed per sample
static int frame_count;
static int loud_frames;
#if COMM_DEBUG
static volatile float debug_peak;
static volatile float debug_level_db = -120;    // the loudest frame
#endif

/* ----- The microphone's task ----- */

static void voice_cb(const int16_t *samples, size_t count, void *user_data)
{
    // One pole high pass at 200 Hz, for hearing speech
    const float hp_a = 1.0f / (1.0f + 2.0f * (float)M_PI * 200.0f / FS);
    const float gain_target = powf(10.0f, agc_db / 20.0f);
    if (agc_gain == 0)
    {
        agc_gain = gain_target;
    }
    uint32_t w = ring_write;
    for (size_t i = 0; i < count; i++)
    {
        float x = samples[i] / 32768.0f;
        agc_gain += (gain_target - agc_gain) * 0.002f;     // about 30 ms
        float v = tanhf(x * agc_gain);  // rounds peaks off instead of clipping them
        ring[w++ & RING_MASK] = (int16_t)(v * 32767.0f);
#if COMM_DEBUG
        if (fabsf(v) > debug_peak)
        {
            debug_peak = fabsf(v);
        }
#endif

        float y = hp_a * (hp_y + x - hp_x);
        hp_x = x;
        hp_y = y;
        frame_energy += y * y;
        frame_full_energy += x * x;
        if (++frame_count == FRAME)
        {
            float db = 10.0f * log10f(frame_energy / FRAME + 1e-12f);
            float full_db = 10.0f * log10f(frame_full_energy / FRAME + 1e-12f);
#if COMM_DEBUG
            if (full_db > debug_level_db)
            {
                debug_level_db = full_db;
            }
#endif
            loud_frames = db > VOX_DB ? loud_frames + 1 : 0;
            if (loud_frames >= VOX_ATTACK)
            {
                voice_until = w + MS_TO_SAMPLES(VOX_HANG_MS);
            }
            // Only the voice moves the gain, not the silence between words.
            // Frames well below the loud parts leave it alone too, so it
            // settles on the loud parts.
            float out_db = full_db + agc_db;
            if (loud_frames > 0 && out_db > AGC_TARGET_DB - 12.0f)
            {
                float error = AGC_TARGET_DB - out_db;
                agc_db += error > 0 ? fminf(error, AGC_UP_DB) : fmaxf(error, -AGC_DOWN_DB);
                agc_db = fmaxf(AGC_MIN_DB, fminf(AGC_MAX_DB, agc_db));
            }
            frame_energy = 0;
            frame_full_energy = 0;
            frame_count = 0;
        }
    }
    voice_heard = (int32_t)(voice_until - w) > 0;
    __atomic_store_n(&ring_write, w, __ATOMIC_RELEASE);
}

/* ----- The encoder's task ----- */

static uint8_t status_flags(void)
{
    return (sending ? STATUS_SENDING : 0) | (voice_heard ? STATUS_HEARD : 0);
}

static bool send_retrying(const uint8_t *data, size_t len)
{
    for (int i = 0; i < SEND_RETRIES; i++)
    {
        if (rcat_hal_ble_peer_send(data, len))
        {
            return true;
        }
        if (!rcat_hal_ble_peer_connected())
        {
            return false;
        }
        rcat_hal_delay_ms(SEND_RETRY_MS);
    }
    return false;
}

static void send_status(void)
{
    uint8_t msg[4] = { MSG_STATUS, COMM_VERSION, (uint8_t)mode, status_flags() };
    send_retrying(msg, sizeof(msg));
}

static bool talking(void)
{
    return screen_talk || phone_talk || (mode == COMM_VOICE && voice_heard);
}

static void encoder_task(void *arg)
{
    int err;
    OpusEncoder *enc = opus_encoder_create(FS, 1, OPUS_APPLICATION_VOIP, &err);
    if (enc == NULL)
    {
        printf("comm: Opus encoder didn't start (%d)\n", err);
        for (;;)
        {
            rcat_hal_delay_ms(1000);
        }
    }
    opus_encoder_ctl(enc, OPUS_SET_BITRATE(OPUS_BITRATE));
    opus_encoder_ctl(enc, OPUS_SET_COMPLEXITY(OPUS_COMPLEXITY));
    opus_encoder_ctl(enc, OPUS_SET_SIGNAL(OPUS_SIGNAL_VOICE));
    opus_encoder_ctl(enc, OPUS_SET_INBAND_FEC(1));
    opus_encoder_ctl(enc, OPUS_SET_PACKET_LOSS_PERC(OPUS_LOSS_PERCENT));

    bool connected = false;
    bool releasing = false;     // let go, and finishing what's left
    uint32_t read = 0;
    uint32_t end = 0;           // where the transmission ends, once it's let go
    uint16_t seq = 0;
    bool first = false;
    uint8_t last_status = 0xFF;
    uint32_t status_ms = 0;
    int16_t pcm[FRAME];
    uint8_t packet[HEADER_BYTES + MAX_OPUS_BYTES];
#if COMM_DEBUG
    uint32_t debug_ms = 0, debug_frames = 0, debug_dropped = 0, debug_bytes = 0;
    clock_t debug_encode = 0;
#endif

    for (;;)
    {
        bool now_connected = running && rcat_hal_ble_peer_connected();
        if (!now_connected)
        {
            connected = false;
            sending = false;
            releasing = false;
            rcat_hal_delay_ms(TASK_IDLE_MS);
            continue;
        }
        if (!connected)
        {
            connected = true;
            last_status = 0xFF;     // tell the new phone how things are
        }

        uint32_t w = __atomic_load_n(&ring_write, __ATOMIC_ACQUIRE);
        bool talk = talking();

        if (!sending && talk)
        {
            uint32_t pre = mode == COMM_VOICE ? MS_TO_SAMPLES(VOX_PREROLL_MS) + VOX_ATTACK * FRAME : 0;
            if (pre > w)
            {
                pre = w;
            }
            read = w - pre;
            sending = true;
            releasing = false;
            first = true;
            opus_encoder_ctl(enc, OPUS_RESET_STATE);
        }
        if (sending && !talk && !releasing)
        {
            releasing = true;
            end = w + (mode == COMM_PUSH_TO_TALK ? MS_TO_SAMPLES(PTT_TAIL_MS) : 0);
        }
        else if (sending && talk)
        {
            releasing = false;      // pressed again before it finished
        }
        if (sending && w - read > MS_TO_SAMPLES(MAX_BEHIND_MS))
        {
            read = w - FRAME;
        }

        while (sending && w - read >= FRAME && !(releasing && (int32_t)(end - read) < FRAME))
        {
            for (int i = 0; i < FRAME; i++)
            {
                pcm[i] = ring[(read + i) & RING_MASK];
            }
            read += FRAME;

            size_t room = rcat_hal_ble_peer_max_send();
            int max_bytes = (int)(room > HEADER_BYTES ? room - HEADER_BYTES : 0);
            if (max_bytes > MAX_OPUS_BYTES)
            {
                max_bytes = MAX_OPUS_BYTES;
            }
            if (max_bytes < 3)
            {
                continue;
            }
#if COMM_DEBUG
            clock_t t0 = clock();
#endif
            int n = opus_encode(enc, pcm, FRAME, packet + HEADER_BYTES, max_bytes);
#if COMM_DEBUG
            debug_encode += clock() - t0;
            debug_frames++;
#endif
            if (n < 0)
            {
                continue;
            }
            packet[0] = MSG_SOUND;
            packet[1] = seq & 0xFF;
            packet[2] = seq >> 8;
            packet[3] = first ? FLAG_FIRST : 0;
            seq++;
            first = false;
            if (!send_retrying(packet, HEADER_BYTES + n))
            {
#if COMM_DEBUG
                debug_dropped++;
#endif
            }
#if COMM_DEBUG
            debug_bytes += n;
#endif
        }

        if (sending && releasing && (int32_t)(end - read) < FRAME)
        {
            packet[0] = MSG_SOUND;
            packet[1] = seq & 0xFF;
            packet[2] = seq >> 8;
            packet[3] = FLAG_LAST | (first ? FLAG_FIRST : 0);
            seq++;
            send_retrying(packet, HEADER_BYTES);
            sending = false;
            releasing = false;
        }

        // Status, when it changes and every few seconds
        status_ms += TASK_BUSY_MS;
        uint8_t now_status = ((uint8_t)mode << 4) | status_flags();
        if (now_status != last_status || status_ms >= STATUS_EVERY_MS)
        {
            last_status = now_status;
            status_ms = 0;
            send_status();
        }

#if COMM_DEBUG
        debug_ms += TASK_BUSY_MS;
        if (debug_ms >= 2000)
        {
            printf("comm: loudest %.0f dB, gain %.1f dB, peak %.2f, %lu frames (%lu dropped), %lu bytes, encoding %.1f%% of a core\n",
                   debug_level_db, agc_db, debug_peak, (unsigned long)debug_frames, (unsigned long)debug_dropped,
                   (unsigned long)debug_bytes,
                   debug_frames ? 100.0 * debug_encode / CLOCKS_PER_SEC / (debug_frames * 0.020) : 0.0);
            debug_peak = 0;
            debug_level_db = -120;
            debug_ms = debug_frames = debug_dropped = debug_bytes = 0;
            debug_encode = 0;
        }
#endif
        rcat_hal_delay_ms(TASK_BUSY_MS);
    }
}

/* ----- The UI loop ----- */

static void parse_uuid(const char *text, uint8_t out[16])
{
    int n = 0;
    for (const char *p = text; *p != '\0' && n < 32; p++)
    {
        int v;
        if (*p >= '0' && *p <= '9')
        {
            v = *p - '0';
        }
        else if (*p >= 'a' && *p <= 'f')
        {
            v = *p - 'a' + 10;
        }
        else if (*p >= 'A' && *p <= 'F')
        {
            v = *p - 'A' + 10;
        }
        else
        {
            continue;   // the dashes
        }
        if (n % 2 == 0)
        {
            out[n / 2] = v << 4;
        }
        else
        {
            out[n / 2] |= v;
        }
        n++;
    }
}

void comm_init(void)
{
    parse_uuid(COMM_SERVICE_UUID, service.service);
    parse_uuid(COMM_TO_PHONE_UUID, service.to_phone);
    parse_uuid(COMM_FROM_PHONE_UUID, service.from_phone);
    rcat_hal_ble_peer_setup(&service);

    const settings_t *s = settings_get();
    mode = s->comm_mode < COMM_MODE_COUNT ? (comm_mode_t)s->comm_mode : COMM_PUSH_TO_TALK;

    if (!voice_fx_start())
    {
        return;     // nothing to send
    }
    ring = calloc(RING, sizeof(ring[0]));
    if (ring == NULL || !rcat_hal_task_start("comm", encoder_task, NULL, TASK_STACK))
    {
        free(ring);
        ring = NULL;
        return;
    }
    available = true;
    if (s->comm_on)
    {
        comm_start();
    }
}

bool comm_available(void)
{
    return available;
}

bool comm_start(void)
{
    if (!available)
    {
        return false;
    }
    if (!running)
    {
        if (!rcat_hal_ble_peer_start(comm_name()))
        {
            return false;
        }
        voice_fx_set_listener(voice_cb, NULL);
        running = true;
    }
    settings_set_comm(1, mode);
    return true;
}

void comm_stop(void)
{
    if (running)
    {
        running = false;
        voice_fx_set_listener(NULL, NULL);
        rcat_hal_ble_peer_stop();
    }
    phone_talk = false;
    screen_talk = false;
    settings_set_comm(0, mode);
}

bool comm_running(void)
{
    return running;
}

comm_mode_t comm_mode(void)
{
    return mode;
}

void comm_set_mode(comm_mode_t m)
{
    if (m < COMM_MODE_COUNT && m != mode)
    {
        mode = m;
        settings_set_comm(running, mode);
    }
}

void comm_set_talk(bool talk)
{
    screen_talk = talk;
}

bool comm_phone_connected(void)
{
    return running && rcat_hal_ble_peer_connected();
}

bool comm_sending(void)
{
    return sending;
}

bool comm_voice_heard(void)
{
    return running && voice_heard;
}

const char *comm_name(void)
{
    return remote_ssid();   // the same name as the phone remote's hotspot
}

void comm_poll(uint32_t now_ms)
{
    if (!running)
    {
        return;
    }
    if (!rcat_hal_ble_peer_connected())
    {
        phone_talk = false;     // so a phone that's gone doesn't leave it talking
        return;
    }
    uint8_t msg[8];
    size_t len;
    while ((len = rcat_hal_ble_peer_receive(msg, sizeof(msg))) > 0)
    {
        if (msg[0] == MSG_TALK && len >= 2)
        {
            phone_talk = msg[1] != 0;
        }
        else if (msg[0] == MSG_MODE && len >= 2)
        {
            comm_set_mode((comm_mode_t)msg[1]);
        }
    }
}

#else   // no comm channel on this platform

void comm_init(void)
{
}

bool comm_available(void)
{
    return false;
}

bool comm_start(void)
{
    return false;
}

void comm_stop(void)
{
}

bool comm_running(void)
{
    return false;
}

comm_mode_t comm_mode(void)
{
    return COMM_PUSH_TO_TALK;
}

void comm_set_mode(comm_mode_t mode)
{
}

void comm_set_talk(bool talk)
{
}

bool comm_phone_connected(void)
{
    return false;
}

bool comm_sending(void)
{
    return false;
}

bool comm_voice_heard(void)
{
    return false;
}

const char *comm_name(void)
{
    return "";
}

void comm_poll(uint32_t now_ms)
{
}

#endif
