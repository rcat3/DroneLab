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

#include <stddef.h>

#if RCAT_HAVE_COMM

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "opus.h"

#include "app/remote.h"
#include "app/settings.h"
#include "app/talk_button.h"
#include "audio/speaker.h"
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
#define AGC_TARGET_DB       -12.0f  // 20 ms level, before limiting; -18 was quiet next to other Mumble users
#define AGC_START_DB        20.0f
#define AGC_MIN_DB          0.0f
#define AGC_MAX_DB          30.0f
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
#define MSG_REQUEST         0x03    // both ways: a request, and its answer
#define MSG_SERVER          0x04
#define MSG_HEARING         0x05
#define MSG_AVATAR          0x06    // both ways: a piece of it, and the ack
#define AVATAR_FIRST        0x01
#define AVATAR_LAST         0x02
#define AVATAR_ACK          0x04
#define AVATAR_DONE         0x01
#define AVATAR_OK           0x02
#define SERVER_CONNECTED    0x01
#define SERVER_CONNECTING   0x02
#define SERVER_UDP          0x04
#define REQ_FIRST           0x01
#define REQ_LAST            0x02
#define REQUEST_MAX         2048    // the method, target and body
#define ANSWER_MAX          8192    // as long as the remote's longest
#define ANSWER_CHUNKS_PER_POLL  6   // at most this many notifications every 50 ms, leaving room for the voice
#define FLAG_FIRST          0x01
#define FLAG_LAST           0x02
#define STATUS_SENDING      0x01
#define STATUS_HEARD        0x02
#define STATUS_BUTTON       0x04
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

// The phone remote's requests, from the UI loop only (see comm.h)
static char *request;               // REQUEST_MAX + 1, then the answer, ANSWER_MAX
static char *answer;
static size_t request_len;
static uint8_t request_id;
static bool request_open;           // its first piece came, and not its last
static char answer_head[4];         // "200\n" and the like
static const char *answer_body;     // the JSON in answer, or the page in flash
static size_t answer_len, answer_sent;  // of the head and body together
static uint8_t answer_id;
static bool answering;
static uint32_t last_state_hash;    // of the last /api/state sent, to say "unchanged"
static char app_version[24];        // what the app said it is
static comm_server_t server_state;  // what the app says about the server
static bool server_udp;
static int server_others;
static char server_channel[COMM_NAME_MAX];
static int hearing_count;
static char hearing[COMM_HEARING_MAX][COMM_NAME_MAX];
static uint8_t hearing_avatar[COMM_HEARING_MAX];
static uint8_t own_avatar = COMM_AVATAR_NONE;
static int avatar_size;
static uint16_t *avatars[COMM_AVATAR_SLOTS];        // allocated as they come; big enough for PSRAM
static uint32_t avatar_got[COMM_AVATAR_SLOTS];      // bytes so far
static bool avatar_ready[COMM_AVATAR_SLOTS];
static uint32_t avatar_changes;
static bool speaker_muted;
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
    return (sending ? STATUS_SENDING : 0) | (voice_heard ? STATUS_HEARD : 0) |
           (talk_button_state() == TALK_BUTTON_CONNECTED ? STATUS_BUTTON : 0);
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
    return screen_talk || phone_talk || talk_button_held() || (mode == COMM_VOICE && voice_heard);
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
    request = malloc(REQUEST_MAX + 1 + ANSWER_MAX);     // big enough to go in PSRAM
    answer = request != NULL ? request + REQUEST_MAX + 1 : NULL;
    ring = calloc(RING, sizeof(ring[0]));
    if (ring == NULL || request == NULL || !rcat_hal_task_start("comm", encoder_task, NULL, TASK_STACK))
    {
        free(ring);
        ring = NULL;
        free(request);
        request = answer = NULL;
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
        talk_button_start();
    }
    settings_set_comm(1, mode);
    return true;
}

void comm_stop(void)
{
    if (running)
    {
        running = false;
        talk_button_stop();
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

bool comm_phone_talking(void)
{
    return running && phone_talk;
}

bool comm_voice_heard(void)
{
    return running && voice_heard;
}

const char *comm_name(void)
{
    return remote_ssid();   // the same name as the phone remote's hotspot
}

const char *comm_app_version(void)
{
    return app_version;
}

comm_server_t comm_server(void)
{
    return server_state;
}

bool comm_server_udp(void)
{
    return server_udp;
}

int comm_server_others(void)
{
    return server_others;
}

const char *comm_server_channel(void)
{
    return server_channel;
}

int comm_hearing_count(void)
{
    return hearing_count;
}

const char *comm_hearing_name(int index)
{
    return index >= 0 && index < hearing_count ? hearing[index] : "";
}

int comm_hearing_avatar(int index)
{
    return index >= 0 && index < hearing_count ? hearing_avatar[index] : COMM_AVATAR_NONE;
}

void comm_set_avatar_size(int px)
{
    if (px != avatar_size)
    {
        for (int i = 0; i < COMM_AVATAR_SLOTS; i++)
        {
            free(avatars[i]);
            avatars[i] = NULL;
            avatar_ready[i] = false;
        }
        avatar_size = px > 0 ? px : 0;
    }
}

int comm_avatar_size(void)
{
    return avatar_size;
}

int comm_own_avatar(void)
{
    return own_avatar;
}

const uint16_t *comm_avatar(int slot)
{
    return slot >= 0 && slot < COMM_AVATAR_SLOTS && avatar_ready[slot] ? avatars[slot] : NULL;
}

uint32_t comm_avatar_changes(void)
{
    return avatar_changes;
}

static uint32_t hash(const char *data, size_t len)
{
    uint32_t h = 2166136261u;   // FNV-1a
    for (size_t i = 0; i < len; i++)
    {
        h = (h ^ (uint8_t)data[i]) * 16777619u;
    }
    return h;
}

/* A whole request has come: "METHOD /api/...\n" then the body. */
static void answer_request(void)
{
    request[request_len] = '\0';
    char *nl = strchr(request, '\n');
    const char *body = nl != NULL ? nl + 1 : request + request_len;
    size_t body_len = request + request_len - body;
    if (nl != NULL)
    {
        *nl = '\0';
    }
    char method[8], target[200];
    int status = 404;
    int len = -1;
    answer_body = answer + 4;
    if (sscanf(request, "%7s %199s", method, target) == 2)
    {
        if (strncmp(target, "/version", 8) == 0)
        {
            const char *v = strstr(target, "app=");
            if (v != NULL)
            {
                size_t n = strcspn(v + 4, "&");
                n = n < sizeof(app_version) - 1 ? n : sizeof(app_version) - 1;
                memcpy(app_version, v + 4, n);
                app_version[n] = '\0';
                printf("comm: app version %s\n", app_version);
            }
            len = snprintf(answer + 4, ANSWER_MAX - 4,
                           "{\"firmware\":\"%s\",\"built\":\"%s\",\"comm\":%d,\"avatar\":%d,\"avatars\":%d}",
                           rcat_hal_firmware_version(), rcat_hal_firmware_built(), COMM_VERSION, avatar_size,
                           COMM_AVATAR_SLOTS);
        }
        else if (strncmp(target, "/remote.html", 12) == 0)
        {
            // The remote's page itself, so the app shows the board's own
            // version. ?h= is the hash of the copy the app has: if it's the
            // same, there's no need to send it.
            size_t page_len;
            const char *page = remote_page_html(&page_len);
            const char *have = strstr(target, "h=");
            if (page != NULL)
            {
                char hex[12];
                snprintf(hex, sizeof(hex), "%08lx", (unsigned long)hash(page, page_len));
                bool same = have != NULL && strncmp(have + 2, hex, 8) == 0;
                memcpy(answer_head, same ? "304\n" : "200\n", 4);
                answer_body = page;
                answer_len = 4 + (same ? 0 : page_len);
                answer_sent = 0;
                answer_id = request_id;
                answering = true;
                return;
            }
        }
        else
        {
            len = remote_api(method, target, body, body_len, answer + 4, ANSWER_MAX - 4);
        }
    }
    if (len >= 0)
    {
        status = 200;
        // The page asks for the state every 0.4 s: say if it's the same.
        if (strncmp(target, "/api/state", 10) == 0 && strcmp(method, "GET") == 0)
        {
            uint32_t h = hash(answer + 4, len);
            if (h == last_state_hash)
            {
                status = 304;
                len = 0;
            }
            last_state_hash = h;
        }
        else
        {
            last_state_hash = 0;    // a change: send the next state in full
        }
    }
    else
    {
        len = 0;
    }
    memcpy(answer_head, status == 200 ? "200\n" : status == 304 ? "304\n" : "404\n", 4);
    answer_len = 4 + len;
    answer_sent = 0;
    answer_id = request_id;
    answering = true;
}

static void receive_request(const uint8_t *msg, size_t len)
{
    if (len < 3 || request == NULL)
    {
        return;
    }
    uint8_t id = msg[1], flags = msg[2];
    if (flags & REQ_FIRST)
    {
        request_id = id;
        request_len = 0;
        request_open = true;
        answering = false;      // a new request drops what's left of the last answer
    }
    if (!request_open || id != request_id)
    {
        return;
    }
    size_t n = len - 3;
    if (request_len + n > REQUEST_MAX)
    {
        n = REQUEST_MAX - request_len;
    }
    memcpy(request + request_len, msg + 3, n);
    request_len += n;
    if (flags & REQ_LAST)
    {
        request_open = false;
        answer_request();
    }
}

/* Send what's left of the answer, a few pieces at a time. */
static void send_answer(void)
{
    size_t room = rcat_hal_ble_peer_max_send();
    if (!answering || room <= 3)
    {
        return;
    }
    uint8_t msg[256];
    size_t piece = room - 3 < sizeof(msg) - 3 ? room - 3 : sizeof(msg) - 3;
    for (int i = 0; i < ANSWER_CHUNKS_PER_POLL && answering; i++)
    {
        size_t n = answer_len - answer_sent < piece ? answer_len - answer_sent : piece;
        msg[0] = MSG_REQUEST;
        msg[1] = answer_id;
        msg[2] = (answer_sent == 0 ? REQ_FIRST : 0) | (answer_sent + n == answer_len ? REQ_LAST : 0);
        for (size_t k = 0; k < n; k++)
        {
            size_t at = answer_sent + k;
            msg[3 + k] = at < 4 ? answer_head[at] : answer_body[at - 4];
        }
        if (!rcat_hal_ble_peer_send(msg, 3 + n))
        {
            return;     // no room just now: carry on next time
        }
        answer_sent += n;
        if (answer_sent == answer_len)
        {
            answering = false;
        }
    }
}

/* Copy at most n bytes of UTF-8 into out (COMM_NAME_MAX), without cutting a
 * character in two. */
static void copy_name(char *out, const uint8_t *text, size_t n)
{
    if (n > COMM_NAME_MAX - 1)
    {
        n = COMM_NAME_MAX - 1;
        while (n > 0 && (text[n] & 0xC0) == 0x80)
        {
            n--;    // text[n] would carry on a character
        }
    }
    memcpy(out, text, n);
    out[n] = '\0';
}

static void receive_server(const uint8_t *msg, size_t len)
{
    if (len < 3)
    {
        return;
    }
    server_state = msg[1] & SERVER_CONNECTED    ? COMM_SERVER_CONNECTED
                   : msg[1] & SERVER_CONNECTING ? COMM_SERVER_CONNECTING
                                                : COMM_SERVER_OFF;
    server_udp = (msg[1] & SERVER_UDP) != 0;
    server_others = msg[2];
    own_avatar = len > 3 ? msg[3] : COMM_AVATAR_NONE;
    copy_name(server_channel, msg + 4, len > 4 ? len - 4 : 0);
}

static void receive_hearing(const uint8_t *msg, size_t len)
{
    hearing_count = 0;
    size_t at = 1;
    while (at + 1 < len && hearing_count < COMM_HEARING_MAX)
    {
        uint8_t slot = msg[at++];
        size_t end = at;
        while (end < len && msg[end] != '\n')
        {
            end++;
        }
        if (end > at)
        {
            hearing_avatar[hearing_count] = slot;
            copy_name(hearing[hearing_count++], msg + at, end - at);
        }
        at = end + 1;
    }
}

static void receive_avatar(const uint8_t *msg, size_t len)
{
    uint8_t slot = msg[1], flags = msg[2];
    size_t total = (size_t)avatar_size * avatar_size * 2;
    if (len < 3 || slot >= COMM_AVATAR_SLOTS || total == 0)
    {
        return;
    }
    if (flags & AVATAR_FIRST)
    {
        if (avatars[slot] == NULL)
        {
            avatars[slot] = malloc(total);
        }
        avatar_got[slot] = 0;
        avatar_ready[slot] = false;
    }
    size_t n = len - 3;
    if (avatars[slot] != NULL && avatar_got[slot] + n <= total)
    {
        memcpy((uint8_t *)avatars[slot] + avatar_got[slot], msg + 3, n);
    }
    avatar_got[slot] += n;
    bool ok = avatars[slot] != NULL && avatar_got[slot] == total;
    if (flags & AVATAR_LAST)
    {
        avatar_ready[slot] = ok;
        if (ok)
        {
            avatar_changes++;
        }
    }
    if (flags & (AVATAR_ACK | AVATAR_LAST))
    {
        uint32_t got = avatar_got[slot];
        uint8_t ack[7] = { MSG_AVATAR, slot,
                           (uint8_t)((flags & AVATAR_LAST ? AVATAR_DONE : 0) | (ok ? AVATAR_OK : 0)),
                           (uint8_t)got, (uint8_t)(got >> 8), (uint8_t)(got >> 16), (uint8_t)(got >> 24) };
        send_retrying(ack, sizeof(ack));
    }
}

static void forget_phone(void)
{
    phone_talk = false;     // so a phone that's gone doesn't leave it talking
    app_version[0] = '\0';
    answering = false;
    request_open = false;
    last_state_hash = 0;
    server_state = COMM_SERVER_UNKNOWN;
    server_udp = false;
    server_others = 0;
    server_channel[0] = '\0';
    hearing_count = 0;
    own_avatar = COMM_AVATAR_NONE;
    // The pictures are kept, but a new phone fills the slots afresh
    for (int i = 0; i < COMM_AVATAR_SLOTS; i++)
    {
        if (avatar_ready[i])
        {
            avatar_ready[i] = false;
            avatar_changes++;
        }
    }
}

void comm_poll(uint32_t now_ms)
{
    // Quiet while it sends, if that's chosen
    bool mute = running && sending && settings_get()->comm_mute_speaker;
    if (mute != speaker_muted)
    {
        speaker_muted = mute;
        speaker_set_muted(mute);
    }
    if (!running)
    {
        forget_phone();
        return;
    }
    if (!rcat_hal_ble_peer_connected())
    {
        forget_phone();
        return;
    }
    uint8_t msg[RCAT_HAL_BLE_PEER_MSG_MAX];
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
        else if (msg[0] == MSG_REQUEST)
        {
            receive_request(msg, len);
        }
        else if (msg[0] == MSG_SERVER)
        {
            receive_server(msg, len);
        }
        else if (msg[0] == MSG_HEARING)
        {
            receive_hearing(msg, len);
        }
        else if (msg[0] == MSG_AVATAR)
        {
            receive_avatar(msg, len);
        }
    }
    send_answer();
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

bool comm_phone_talking(void)
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

const char *comm_app_version(void)
{
    return "";
}

comm_server_t comm_server(void)
{
    return COMM_SERVER_UNKNOWN;
}

bool comm_server_udp(void)
{
    return false;
}

int comm_server_others(void)
{
    return 0;
}

const char *comm_server_channel(void)
{
    return "";
}

int comm_hearing_count(void)
{
    return 0;
}

const char *comm_hearing_name(int index)
{
    return "";
}

int comm_hearing_avatar(int index)
{
    return COMM_AVATAR_NONE;
}

void comm_set_avatar_size(int px)
{
}

int comm_avatar_size(void)
{
    return 0;
}

int comm_own_avatar(void)
{
    return COMM_AVATAR_NONE;
}

const uint16_t *comm_avatar(int slot)
{
    return NULL;
}

uint32_t comm_avatar_changes(void)
{
    return 0;
}

void comm_poll(uint32_t now_ms)
{
}

#endif
