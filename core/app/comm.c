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

#include "app/battery.h"
#include "app/direct.h"
#include "app/others.h"
#include "app/remote.h"
#include "app/settings.h"
#include "app/talk_button.h"
#include "app/updater.h"
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
#define OPUS_RECORD_BITRATE 48000   // for recording: no coding to hear, and room for it on Bluetooth
#define OPUS_COMPLEXITY     3
#define OPUS_LOSS_PERCENT   5
#define MAX_OPUS_BYTES      200
#define HEADER_BYTES        4

#define MSG_SOUND           0x01
#define MSG_STATUS          0x02
#define MSG_TALK            0x01
#define MSG_MODE            0x02
#define MSG_REQUEST         0x03    // both ways: a request, and its answer
#define MSG_SERVER          0x04
#define MSG_HEARING         0x05
#define MSG_AVATAR          0x06    // both ways: a piece of it, and the ack
#define MSG_DIRECT_SOUND    0x07    // to the phone: what's heard over direct comms
#define MSG_DIRECT_PEER     0x08    // to the phone: a board that's about
#define MSG_DIRECT_GROUP    0x09    // to the phone: a group heard about
#define DIRECT_PEERS_EVERY_MS 2000
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
#define STATUS_RECORDING    0x08
#define STATUS_OTHER_VOICE  0x10    // someone's talking in another direct comms group nearby
#define STATUS_OTHER_FIRMWARE 0x20  // boards with another version of direct comms nearby
#define MSG_UPDATE          0x0E    // both ways: the firmware from the app, and the ack
#define UPDATE_START        0x01
#define UPDATE_END          0x02
#define UPDATE_ACK          0x04
#define UPDATE_DONE         0x01    // in the ack
#define UPDATE_WELL         0x02
#define UPDATE_INSTALLING   0x04    // in the ack: it's all here, and being installed
#define MSG_RECORD          0x0A    // both ways: start or stop recording, and what's recorded
#define RECORD_SPEAKER      0x01    // the speaker's voice effect, not the comm voice
#define RECORD_BEEP         0x02    // with a sync beep to start
#define MSG_COMMAND         0x0B    // from the phone: a command for others, in from the server or out over direct
#define COMMAND_FROM_SERVER 0x01
#define MSG_MUTED           0x10    // from the phone: who's muted there, whose commands are ignored
#define MUTED_FIRST         0x01
#define MSG_IDENTITY        0x11    // from the phone: the wearer's public key
#define MSG_BINDING         0x12    // from the phone: the wearer's signature that this board's theirs
#define MSG_HEARD           0x0F    // to the phone: a text or command someone sent, done or not
#define MSG_DIRECT_AVATAR   0x0D    // to the phone: a piece of a board's avatar, heard over direct comms
#define PEER_AVATAR_PIECE   100     // pixels a piece
#define PEER_AVATAR_SETTLE_MS 2000  // sent once it's stopped changing this long
#define PEER_AVATAR_BURST   6       // pieces each comm_poll
#define HEARD_DIRECT        0x01
#define HEARD_DONE          0x02
#define HEARD_COUNTER       0x04    // the command's counter follows the key
#define MSG_COPY            0x15    // to the phone: a copy of a command heard over direct comms, how it came
#define MSG_TALK_TO         0x13    // from the phone: who talking goes to
#define TALK_TO_ON_SERVER   0x01
#define MSG_TALKED          0x13    // to the phone: a transmission started, ended or was refused
#define TALKED_STARTED      0
#define TALKED_ENDED        1
#define TALKED_REFUSED      2
#define TALKED_BY_VOICE     0x01
#define TALKED_DIRECT       0x02
#define TALKED_ALONE        0x04
#define MSG_PAIRS           0x14    // from the phone: the pairs' keys, for talking to one alone over direct comms
#define PAIRS_FIRST         0x01
#define PAIR_ENTRY          (OTHERS_KEY_LEN + DIRECT_KEY_LEN)
#define REFUSED_SHOWN_MS    1500    // the screen says nobody would hear, for this long
// The beep comes out of the speaker about this long after the speaker's
// task makes it (as voice_lab.c), so it's put in the recording then too
#define BEEP_OUT_DELAY_MS   25
// And what the microphone hears is left out while it beeps, and this long
// after, so the beep it picks up from the speaker, late from the effect,
// isn't in the recording as a second one
#define BEEP_MUTE_TAIL_MS   150
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
static char app_os[12];             // and what it runs on: "Android", "iPhone"
static comm_server_t server_state;  // what the app says about the server
static bool server_udp;
static int server_others;
static char server_channel[COMM_NAME_MAX];
// Who's talking: as the phone says, and with those heard over direct comms
// that it hasn't named, which is what's shown
static int phone_hearing_count;
static char phone_hearing[COMM_HEARING_MAX][COMM_NAME_MAX];
static uint8_t phone_hearing_avatar[COMM_HEARING_MAX];
static uint8_t phone_hearing_transport[COMM_HEARING_MAX];
static int hearing_count;
static char hearing[COMM_HEARING_MAX][COMM_NAME_MAX];
static uint8_t hearing_avatar[COMM_HEARING_MAX];
static uint8_t hearing_transport[COMM_HEARING_MAX];
static bool audio_on;               // the voice is listened to, and the talk button used
static volatile comm_transport_t tx_transport;  // how the transmission going out goes
static volatile bool tx_alone;                  // to one person alone, over direct comms

// Who talking goes to: the UI loop writes it, the encoder copies it whole
// (target_seq is odd while it's being written)
typedef struct
{
    comm_to_t to;
    bool on_server;                 // the person's on the server, as the app says
    uint8_t key[OTHERS_KEY_LEN];    // theirs
    char name[COMM_NAME_MAX];
} target_t;
static target_t target;
static volatile uint32_t target_seq;
static volatile uint32_t refused_ms;            // when talking was last refused, 0 for never
static volatile bool recording;     // the phone's recording what's said, and nothing goes anywhere else
static uint32_t beep_seen;          // speaker_beep_count(), by the microphone's task
static uint32_t beep_pos = UINT32_MAX;  // samples since the speaker made it, UINT32_MAX while there's none
static uint32_t direct_peers_ms;

static void direct_voice(uint32_t sender, uint16_t seq, uint8_t flags, const uint8_t *opus, size_t len, void *arg);
static uint8_t own_avatar = COMM_AVATAR_NONE;
static int avatar_size;
static uint16_t *avatars[COMM_AVATAR_SLOTS];        // allocated as they come; big enough for PSRAM
static uint32_t avatar_got[COMM_AVATAR_SLOTS];      // bytes so far
static bool avatar_ready[COMM_AVATAR_SLOTS];
static uint32_t avatar_changes;
// A new start of the app, maybe on the same link: it's to have the avatars
// of the boards heard over direct comms again
static bool app_started;
static bool speaker_muted;
static bool pairing_open;
static uint32_t pairing_until;
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
    uint32_t w0 = w;
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

    // Recording: the sync beep, in the recording as it comes out of the
    // speaker, to line it up with video
    uint32_t beeps = speaker_beep_count();
    if (beeps != beep_seen)
    {
        beep_seen = beeps;
        beep_pos = 0;
    }
    if (beep_pos != UINT32_MAX)
    {
        uint32_t start = FS * BEEP_OUT_DELAY_MS / 1000, end = start + FS * SPEAKER_BEEP_MS / 1000;
        uint32_t quiet_end = end + FS * BEEP_MUTE_TAIL_MS / 1000;
        const float step = 2.0f * (float)M_PI * SPEAKER_BEEP_HZ / FS;
        for (uint32_t k = w0; k != w && beep_pos < quiet_end; k++, beep_pos++)
        {
            if (recording && beep_pos >= start)
            {
                // Just the beep: not the microphone, which hears it too
                uint32_t pos = beep_pos - start;
                ring[k & RING_MASK] = beep_pos < end ? (int16_t)(sinf(step * pos) * speaker_beep_envelope(pos, FS) *
                                                                 SPEAKER_BEEP_LEVEL * 32767.0f)
                                                     : 0;
            }
        }
        if (beep_pos >= quiet_end)
        {
            beep_pos = UINT32_MAX;
        }
    }
    __atomic_store_n(&ring_write, w, __ATOMIC_RELEASE);
}

/* ----- The encoder's task ----- */

static uint8_t status_flags(void)
{
    return (sending ? STATUS_SENDING : 0) | (voice_heard ? STATUS_HEARD : 0) | (recording ? STATUS_RECORDING : 0) |
           (talk_button_state() == TALK_BUTTON_CONNECTED ? STATUS_BUTTON : 0) |
           (direct_other_voice() ? STATUS_OTHER_VOICE : 0) |
           (direct_other_firmware() ? STATUS_OTHER_FIRMWARE : 0);
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
    battery_status_t b;
    uint8_t charge = 0xFF;
    if (battery_latest(&b))
    {
        charge = (uint8_t)((b.percent > 100 ? 100 : b.percent) | (b.charging_known && b.charging ? 0x80 : 0));
    }
    uint32_t id = direct_own_id();
    uint8_t msg[9] = { MSG_STATUS, COMM_VERSION, (uint8_t)mode, status_flags(), charge,
                       (uint8_t)id, (uint8_t)(id >> 8), (uint8_t)(id >> 16), (uint8_t)(id >> 24) };
    send_retrying(msg, sizeof(msg));
}

static void copy_target(target_t *out)
{
    uint32_t seq;
    do
    {
        seq = __atomic_load_n(&target_seq, __ATOMIC_SEQ_CST);
        memcpy(out, &target, sizeof(target));
        __atomic_thread_fence(__ATOMIC_SEQ_CST);
    } while ((seq & 1) || seq != __atomic_load_n(&target_seq, __ATOMIC_SEQ_CST));
}

static void set_target(const target_t *t)
{
    __atomic_add_fetch(&target_seq, 1, __ATOMIC_SEQ_CST);
    target = *t;
    __atomic_add_fetch(&target_seq, 1, __ATOMIC_SEQ_CST);
}

typedef enum
{
    ROUTE_NONE,             // nobody would hear it
    ROUTE_SERVER,
    ROUTE_DIRECT,           // to the group
    ROUTE_DIRECT_ALONE,     // to one person, sealed for them
} route_t;

/* How talking would go to who it's for now, if anyone would hear it: one
 * person over direct comms if their board's about, else over the server.
 * From any task: what it reads is set whole. */
static route_t choose_route(const target_t *t)
{
    // The server, through the phone; an app that doesn't say, as if it's there
    bool phone = running && rcat_hal_ble_peer_connected();
    bool server_up = phone && (server_state == COMM_SERVER_CONNECTED || server_state == COMM_SERVER_UNKNOWN);
    bool direct_up = direct_running();
    switch (t->to)
    {
    case COMM_TO_PERSON:
        if (direct_up && direct_can_reach(t->key))
        {
            return ROUTE_DIRECT_ALONE;
        }
        return phone && server_state == COMM_SERVER_CONNECTED && t->on_server ? ROUTE_SERVER : ROUTE_NONE;
    case COMM_TO_DIRECT:
    {
        direct_peer_t peers[DIRECT_PEERS_MAX];
        return direct_up && direct_peers(peers, DIRECT_PEERS_MAX) > 0 ? ROUTE_DIRECT : ROUTE_NONE;
    }
    default:
        if (!phone && direct_up)
        {
            // No phone, so no server: the direct channel, as without the app
            direct_peer_t peers[DIRECT_PEERS_MAX];
            return direct_peers(peers, DIRECT_PEERS_MAX) > 0 ? ROUTE_DIRECT : ROUTE_NONE;
        }
        return server_up && (server_state == COMM_SERVER_UNKNOWN || server_others > 0) ? ROUTE_SERVER : ROUTE_NONE;
    }
}

/* Tell the phone a transmission started, ended or was refused. */
static void send_talked(uint8_t what, uint8_t flags)
{
    uint8_t msg[3] = { MSG_TALKED, what, flags };
    send_retrying(msg, sizeof(msg));
}

static bool talking(void)
{
    return recording || screen_talk || phone_talk || talk_button_held() || (mode == COMM_VOICE && voice_heard);
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
    bool tx_record = false;     // the transmission going out is a recording
    bool refused = false;       // nobody would hear it: not until it's let go, and talked again
    uint8_t tx_flags = 0;       // TALKED_*, for its end
    uint8_t tx_key[OTHERS_KEY_LEN];     // who it's for alone
    uint16_t last_status = 0xFFFF;
    uint32_t status_ms = 0;
    int16_t pcm[FRAME];
    uint8_t packet[HEADER_BYTES + MAX_OPUS_BYTES];
#if COMM_DEBUG
    uint32_t debug_ms = 0, debug_frames = 0, debug_dropped = 0, debug_bytes = 0;
    clock_t debug_encode = 0;
#endif

    for (;;)
    {
        // Sending to the phone, over direct comms, or both
        bool phone = running && rcat_hal_ble_peer_connected();
        bool direct = direct_running();
        if (!phone && !direct)
        {
            connected = false;
            sending = false;
            releasing = false;
            rcat_hal_delay_ms(TASK_IDLE_MS);
            continue;
        }
        if (phone && !connected)
        {
            last_status = 0xFFFF;     // tell the new phone how things are
        }
        connected = phone;

        uint32_t w = __atomic_load_n(&ring_write, __ATOMIC_ACQUIRE);
        // A recording starting or stopping ends what's going out first
        bool rec = recording;
        bool want = talking() && !(sending && tx_record != rec);
        refused = refused && want;
        bool talk = want && !refused;
        route_t route = ROUTE_SERVER;   // a recording's, to the phone

        if (!sending && talk && !rec)
        {
            // Who it's for, and whether anyone would hear it
            target_t t;
            copy_target(&t);
            route = choose_route(&t);
            bool by_voice = mode == COMM_VOICE && !screen_talk && !phone_talk && !talk_button_held();
            tx_flags = (uint8_t)((by_voice ? TALKED_BY_VOICE : 0) |
                                 (route == ROUTE_DIRECT || route == ROUTE_DIRECT_ALONE ? TALKED_DIRECT : 0) |
                                 (t.to == COMM_TO_PERSON ? TALKED_ALONE : 0));
            if (route == ROUTE_NONE)
            {
                refused = true;
                talk = false;
                __atomic_store_n(&refused_ms, rcat_hal_millis() | 1, __ATOMIC_RELEASE);     // never 0
                if (phone)
                {
                    send_talked(TALKED_REFUSED, tx_flags);
                }
            }
            memcpy(tx_key, t.key, sizeof(tx_key));
        }

        if (!sending && talk)
        {
            uint32_t pre = mode == COMM_VOICE && !rec ? MS_TO_SAMPLES(VOX_PREROLL_MS) + VOX_ATTACK * FRAME : 0;
            if (pre > w)
            {
                pre = w;
            }
            read = w - pre;
            // One way, for the whole transmission
            tx_transport = route == ROUTE_SERVER ? COMM_TALK_SERVER : COMM_TALK_DIRECT;
            tx_alone = route == ROUTE_DIRECT_ALONE;
            tx_record = rec;
            if (phone && !rec)
            {
                send_talked(TALKED_STARTED, tx_flags);
            }
            sending = true;
            releasing = false;
            first = true;
            opus_encoder_ctl(enc, OPUS_RESET_STATE);
            opus_encoder_ctl(enc, OPUS_SET_BITRATE(rec ? OPUS_RECORD_BITRATE : OPUS_BITRATE));
        }
        if (sending && !talk && !releasing)
        {
            releasing = true;
            end = w + (mode == COMM_PUSH_TO_TALK && !tx_record ? MS_TO_SAMPLES(PTT_TAIL_MS) : 0);
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

            size_t room = phone ? rcat_hal_ble_peer_max_send() : HEADER_BYTES + MAX_OPUS_BYTES;
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
            packet[0] = tx_record ? MSG_RECORD : MSG_SOUND;
            packet[1] = seq & 0xFF;
            packet[2] = seq >> 8;
            packet[3] = first ? FLAG_FIRST : 0;
            seq++;
            first = false;
            if (direct && !tx_record && tx_transport == COMM_TALK_DIRECT)
            {
                direct_send_voice((uint16_t)(seq - 1), packet[3], packet + HEADER_BYTES, (size_t)n,
                                  tx_alone ? tx_key : NULL);
            }
            if (phone && (tx_record || tx_transport == COMM_TALK_SERVER) && !send_retrying(packet, HEADER_BYTES + n))
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
            packet[0] = tx_record ? MSG_RECORD : MSG_SOUND;
            packet[1] = seq & 0xFF;
            packet[2] = seq >> 8;
            packet[3] = FLAG_LAST | (first ? FLAG_FIRST : 0);
            seq++;
            if (direct && !tx_record && tx_transport == COMM_TALK_DIRECT)
            {
                direct_send_voice((uint16_t)(seq - 1), packet[3], NULL, 0, tx_alone ? tx_key : NULL);
            }
            if (phone && (tx_record || tx_transport == COMM_TALK_SERVER))
            {
                send_retrying(packet, HEADER_BYTES);
            }
            if (phone && !tx_record)
            {
                send_talked(TALKED_ENDED, tx_flags);
            }
            sending = false;
            releasing = false;
        }

        // Status, when it changes and every few seconds
        status_ms += TASK_BUSY_MS;
        uint16_t now_status = (uint16_t)((uint8_t)mode << 8) | status_flags();
        if (phone && (now_status != last_status || status_ms >= STATUS_EVERY_MS))
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
    target_t t = { .to = s->comm_talk_on == COMM_TALK_DIRECT ? COMM_TO_DIRECT : COMM_TO_SERVER };
    set_target(&t);

    if (!voice_fx_start())
    {
        return;     // nothing to send
    }
    voice_fx_set_comm_preset(comm_voice_effect());
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
    direct_set_voice_cb(direct_voice, NULL);
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

void comm_talk_to_channel(comm_transport_t channel)
{
    if (channel >= COMM_TALK_COUNT)
    {
        return;
    }
    target_t t = { .to = channel == COMM_TALK_DIRECT ? COMM_TO_DIRECT : COMM_TO_SERVER };
    set_target(&t);
    if (settings_get()->comm_talk_on != channel)
    {
        settings_set_comm_talk_on((uint8_t)channel);
    }
}

comm_to_t comm_talk_to(void)
{
    return target.to;
}

comm_to_t comm_talk_to_now(void)
{
    // No phone, so no server: talking goes to the direct channel meanwhile
    bool phone = running && rcat_hal_ble_peer_connected();
    return target.to == COMM_TO_SERVER && !phone && direct_running() ? COMM_TO_DIRECT : target.to;
}

const char *comm_talk_to_name(void)
{
    switch (comm_talk_to_now())
    {
    case COMM_TO_PERSON:
        return target.name;
    case COMM_TO_DIRECT:
        return direct_group_name();
    default:
        return server_channel[0] ? server_channel : "SERVER";
    }
}

comm_transport_t comm_talk_now(void)
{
    if (sending)
    {
        return tx_transport;
    }
    target_t t;
    copy_target(&t);
    route_t r = choose_route(&t);
    return r == ROUTE_SERVER                        ? COMM_TALK_SERVER
           : r != ROUTE_NONE || t.to == COMM_TO_DIRECT ? COMM_TALK_DIRECT
                                                     : COMM_TALK_SERVER;
}

bool comm_talk_heard(void)
{
    target_t t;
    copy_target(&t);
    return sending || choose_route(&t) != ROUTE_NONE;
}

bool comm_talk_refused(void)
{
    uint32_t at = __atomic_load_n(&refused_ms, __ATOMIC_ACQUIRE);
    return at != 0 && rcat_hal_millis() - at < REFUSED_SHOWN_MS;
}

bool comm_recording(void)
{
    return recording;
}

void comm_set_voice_effect(int preset)
{
    if (preset >= (int)voice_fx_preset_count())
    {
        preset = -1;
    }
    if (!settings_speaker_fitted())
    {
        // Without a speaker there's one effect, the Voice page's, and it's
        // HiveMind's: setting one sets that
        if (preset >= 0)
        {
            voice_fx_set_preset((size_t)preset);
            settings_set_voice_effect((uint8_t)preset);
        }
        preset = -1;
    }
    voice_fx_set_comm_preset(preset);
    settings_set_comm_voice_effect(preset);
}

int comm_voice_effect(void)
{
    if (!settings_speaker_fitted())
    {
        return -1;      // the Voice page's, the only one (see comm_set_voice_effect)
    }
    int v = settings_get()->comm_voice_effect;
    return v > 0 && v <= (int)voice_fx_preset_count() ? v - 1 : -1;
}

bool comm_phone_connected(void)
{
    return running && rcat_hal_ble_peer_connected();
}

void comm_heard_to_phone(comm_transport_t via, const char *from, const uint8_t *key, uint64_t counter,
                         comm_heard_t what, uint8_t scope, bool done, const uint8_t *data, size_t len)
{
    if (!comm_phone_connected())
    {
        return;
    }
    uint8_t msg[RCAT_HAL_BLE_PEER_MSG_MAX];
    size_t n = strlen(from);
    n = n < COMM_NAME_MAX ? n : COMM_NAME_MAX;
    msg[0] = MSG_HEARD;
    msg[1] = (via == COMM_TALK_DIRECT ? HEARD_DIRECT : 0) | (done ? HEARD_DONE : 0) | HEARD_COUNTER;
    msg[2] = (uint8_t)what;
    msg[3] = scope;
    msg[4] = (uint8_t)n;
    memcpy(msg + 5, from, n);
    size_t at = 5 + n;
    memcpy(msg + at, key, OTHERS_KEY_LEN);
    at += OTHERS_KEY_LEN;
    for (int i = 0; i < 6; i++)
    {
        msg[at++] = (uint8_t)(counter >> (8 * i));
    }
    len = len < sizeof(msg) - at ? len : sizeof(msg) - at;
    memcpy(msg + at, data, len);
    send_retrying(msg, at + len);
}

void comm_copy_to_phone(const uint8_t *key, uint64_t counter, uint32_t broadcast, int8_t rssi, uint8_t hops,
                        uint8_t len)
{
    if (!comm_phone_connected())
    {
        return;
    }
    uint8_t msg[1 + OTHERS_ID_LEN + 6 + 4 + 3];
    size_t at = 0;
    msg[at++] = MSG_COPY;
    memcpy(msg + at, key, OTHERS_ID_LEN);
    at += OTHERS_ID_LEN;
    for (int i = 0; i < 6; i++)
    {
        msg[at++] = (uint8_t)(counter >> (8 * i));
    }
    for (int i = 0; i < 4; i++)
    {
        msg[at++] = (uint8_t)(broadcast >> (8 * i));
    }
    msg[at++] = (uint8_t)rssi;
    msg[at++] = hops;
    msg[at++] = len;
    send_retrying(msg, at);
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

const char *comm_app_os(void)
{
    return app_os;
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

int comm_hearing_transport(int index)
{
    return index >= 0 && index < hearing_count ? hearing_transport[index] : COMM_TALK_SERVER;
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
                const char *os = strstr(target, "os=");
                n = os == NULL ? 0 : strcspn(os + 3, "&");
                n = n < sizeof(app_os) - 1 ? n : sizeof(app_os) - 1;
                memcpy(app_os, os == NULL ? "" : os + 3, n);
                app_os[n] = '\0';
                printf("comm: app version %s %s\n", app_version, app_os);
                app_started = true;
            }
            len = snprintf(answer + 4, ANSWER_MAX - 4,
                           "{\"firmware\":\"%s\",\"built\":\"%s\",\"comm\":%d,\"avatar\":%d,\"avatars\":%d,"
                           "\"board\":\"%s\",\"update\":%d,\"msgmax\":%d,\"msgs\":%d}",
                           rcat_hal_firmware_version(), rcat_hal_firmware_built(), COMM_VERSION, avatar_size,
                           COMM_AVATAR_SLOTS, RCAT_BOARD_NAME, updater_app_available() ? 1 : 0,
                           RCAT_HAL_BLE_PEER_MSG_MAX, RCAT_HAL_BLE_PEER_MSGS);
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
    phone_hearing_count = 0;
    size_t at = 1;
    while (at + 2 < len && phone_hearing_count < COMM_HEARING_MAX)
    {
        uint8_t slot = msg[at++];
        uint8_t transport = msg[at++];
        size_t end = at;
        while (end < len && msg[end] != '\n')
        {
            end++;
        }
        if (end > at)
        {
            phone_hearing_avatar[phone_hearing_count] = slot;
            phone_hearing_transport[phone_hearing_count] = transport < COMM_TALK_COUNT ? transport : COMM_TALK_SERVER;
            copy_name(phone_hearing[phone_hearing_count++], msg + at, end - at);
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

static void set_recording(bool on, bool speaker, bool beep)
{
    if (on != recording)
    {
        printf("comm: recording %s\n", on ? "on" : "off");
    }
    voice_fx_listen_to_speaker(on && speaker);
    recording = on;
    if (on && beep)
    {
        speaker_beep();
    }
}

static void forget_phone(void)
{
    updater_app_cancel();   // an update from it that hasn't finished
    phone_talk = false;     // so a phone that's gone doesn't leave it talking
    if (recording)
    {
        set_recording(false, false, false);     // nor recording
    }
    app_os[0] = '\0';
    app_version[0] = '\0';
    answering = false;
    request_open = false;
    last_state_hash = 0;
    server_state = COMM_SERVER_UNKNOWN;
    server_udp = false;
    server_others = 0;
    server_channel[0] = '\0';
    phone_hearing_count = 0;
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

/* Listen to the voice, and use the talk button, while the phone's link or
 * direct comms is on. */
static void update_audio(void)
{
    bool on = running || direct_running();
    if (on == audio_on)
    {
        return;
    }
    audio_on = on;
    voice_fx_set_listener(on ? voice_cb : NULL, NULL);
    if (on)
    {
        talk_button_start();
    }
    else
    {
        talk_button_stop();
        screen_talk = false;
    }
}

/* What's shown: who the phone says is talking; or, with no phone, those
 * heard over direct comms. */
static void merge_hearing(void)
{
    hearing_count = 0;
    for (int i = 0; i < phone_hearing_count; i++)
    {
        memcpy(hearing[hearing_count], phone_hearing[i], COMM_NAME_MAX);
        hearing_transport[hearing_count] = phone_hearing_transport[i];
        hearing_avatar[hearing_count++] = phone_hearing_avatar[i];
    }
    // With a phone, its list is the whole of it: it has those heard directly
    // too, but for any muted there
    if (!direct_running() || comm_phone_connected())
    {
        return;
    }
    direct_peer_t peers[DIRECT_PEERS_MAX];
    int n = direct_peers(peers, DIRECT_PEERS_MAX);
    for (int i = 0; i < n && hearing_count < COMM_HEARING_MAX; i++)
    {
        bool named = false;
        for (int k = 0; k < hearing_count && !named; k++)
        {
            named = strcmp(hearing[k], peers[i].name) == 0;
        }
        if (peers[i].talking && !named)
        {
            copy_name(hearing[hearing_count], (const uint8_t *)peers[i].name, strlen(peers[i].name));
            hearing_transport[hearing_count] = COMM_TALK_DIRECT;
            hearing_avatar[hearing_count++] = COMM_AVATAR_NONE;
        }
    }
}

/* The boards' avatars heard over direct comms, passed on to the phone once
 * each has stopped changing, a few pieces at a time. */
typedef struct
{
    uint32_t id;            // 0 for a free slot
    uint8_t version;        // as direct_avatar() last said
    uint32_t changed_ms;
    uint8_t sent;           // the version the phone has
    bool sent_any;
} peer_avatar_t;
static peer_avatar_t peer_avatar[DIRECT_PEERS_MAX];
static uint32_t avatar_out_id;
static const uint16_t *avatar_out;
static int avatar_out_piece = -1;

static void send_direct_avatars(uint32_t now_ms)
{
    if (!comm_phone_connected() || !direct_running() || app_started)
    {
        app_started = false;
        memset(peer_avatar, 0, sizeof(peer_avatar));    // all again for the next phone, or app
        avatar_out_piece = -1;
        return;
    }
    const int total = DIRECT_AVATAR_PX * DIRECT_AVATAR_PX;
    const int count = (total + PEER_AVATAR_PIECE - 1) / PEER_AVATAR_PIECE;
    if (avatar_out_piece >= 0)
    {
        for (int k = 0; k < PEER_AVATAR_BURST && avatar_out_piece < count; k++)
        {
            uint8_t msg[8 + 2 * PEER_AVATAR_PIECE];
            int at = avatar_out_piece * PEER_AVATAR_PIECE;
            int n = total - at < PEER_AVATAR_PIECE ? total - at : PEER_AVATAR_PIECE;
            msg[0] = MSG_DIRECT_AVATAR;
            memcpy(msg + 1, &avatar_out_id, 4);
            msg[5] = DIRECT_AVATAR_PX;
            msg[6] = (uint8_t)avatar_out_piece;
            msg[7] = (uint8_t)count;
            for (int i = 0; i < n; i++)
            {
                uint16_t p = avatar_out[at + i];
                msg[8 + 2 * i] = (uint8_t)p;
                msg[9 + 2 * i] = (uint8_t)(p >> 8);
            }
            if (!rcat_hal_ble_peer_send(msg, 8 + 2 * (size_t)n))
            {
                return;     // full: carry on next time
            }
            avatar_out_piece++;
        }
        if (avatar_out_piece >= count)
        {
            avatar_out_piece = -1;
        }
        return;
    }
    direct_peer_t peers[DIRECT_PEERS_MAX];
    int n = direct_peers(peers, DIRECT_PEERS_MAX);
    for (int i = 0; i < n; i++)
    {
        uint8_t version;
        const uint16_t *pixels = direct_avatar(peers[i].name, &version);
        if (pixels == NULL)
        {
            continue;
        }
        peer_avatar_t *slot = NULL;
        for (int k = 0; k < DIRECT_PEERS_MAX && slot == NULL; k++)
        {
            slot = peer_avatar[k].id == peers[i].id ? &peer_avatar[k] : NULL;
        }
        for (int k = 0; k < DIRECT_PEERS_MAX && slot == NULL; k++)
        {
            // A free one, or one for a board that's gone
            bool about = false;
            for (int j = 0; j < n && !about; j++)
            {
                about = peers[j].id == peer_avatar[k].id;
            }
            if (!about)
            {
                slot = &peer_avatar[k];
                memset(slot, 0, sizeof(*slot));
                slot->id = peers[i].id;
                slot->version = version;
                slot->changed_ms = now_ms;
            }
        }
        if (slot == NULL)
        {
            continue;
        }
        if (version != slot->version)
        {
            slot->version = version;
            slot->changed_ms = now_ms;
        }
        else if ((!slot->sent_any || slot->sent != version) && now_ms - slot->changed_ms >= PEER_AVATAR_SETTLE_MS)
        {
            slot->sent = version;
            slot->sent_any = true;
            avatar_out_id = peers[i].id;
            avatar_out = pixels;
            avatar_out_piece = 0;
            return;
        }
    }
}

/* Tell the phone who's about over direct comms, every couple of seconds. */
static void send_direct_peers(uint32_t now_ms)
{
    if (!direct_running() || now_ms - direct_peers_ms < DIRECT_PEERS_EVERY_MS)
    {
        return;
    }
    direct_peers_ms = now_ms;
    direct_peer_t peers[DIRECT_PEERS_MAX];
    int n = direct_peers(peers, DIRECT_PEERS_MAX);
    for (int i = 0; i < n; i++)
    {
        uint8_t msg[7 + sizeof(peers[i].key) + 2 * DIRECT_VERSION_MAX + DIRECT_NAME_MAX];
        msg[0] = MSG_DIRECT_PEER;
        memcpy(msg + 1, &peers[i].id, 4);
        msg[5] = (uint8_t)peers[i].rssi;
        msg[6] = (peers[i].talking ? 1 : 0) | 2 | (peers[i].has_key ? 4 : 0);
        size_t at = 7;
        if (peers[i].has_key)
        {
            memcpy(msg + at, peers[i].key, sizeof(peers[i].key));
            at += sizeof(peers[i].key);
        }
        const char *versions[2] = { peers[i].firmware, peers[i].app };
        for (int k = 0; k < 2; k++)
        {
            size_t v = strlen(versions[k]);
            msg[at++] = (uint8_t)v;
            memcpy(msg + at, versions[k], v);
            at += v;
        }
        size_t len = strlen(peers[i].name);
        memcpy(msg + at, peers[i].name, len);
        rcat_hal_ble_peer_send(msg, at + len);
    }
    direct_group_t groups[DIRECT_GROUPS_MAX];
    n = direct_groups(groups, DIRECT_GROUPS_MAX);
    for (int i = 0; i < n; i++)
    {
        uint8_t msg[9 + DIRECT_NAME_MAX];
        size_t len = strlen(groups[i].name);
        msg[0] = MSG_DIRECT_GROUP;
        memcpy(msg + 1, groups[i].id, 4);
        msg[5] = (uint8_t)groups[i].rssi;
        msg[6] = (uint8_t)groups[i].boards;
        msg[7] = groups[i].channel;
        msg[8] = groups[i].long_range ? 1 : 0;
        memcpy(msg + 9, groups[i].name, len);
        rcat_hal_ble_peer_send(msg, 9 + len);
    }
}

/* What's heard over direct comms goes on to the phone, to play. On direct
 * comms' task. */
static void direct_voice(uint32_t sender, uint16_t seq, uint8_t flags, const uint8_t *opus, size_t len, void *arg)
{
    if (!running || recording || !rcat_hal_ble_peer_connected())
    {
        return;
    }
    uint8_t msg[8 + MAX_OPUS_BYTES];
    if (len > MAX_OPUS_BYTES)
    {
        return;
    }
    msg[0] = MSG_DIRECT_SOUND;
    memcpy(msg + 1, &sender, 4);
    msg[5] = (uint8_t)seq;
    msg[6] = (uint8_t)(seq >> 8);
    msg[7] = flags;
    memcpy(msg + 8, opus, len);
    send_retrying(msg, 8 + len);
}

void comm_allow_pairing(bool allow, uint32_t now_ms)
{
    pairing_open = allow && running;
    pairing_until = now_ms + COMM_PAIRING_MS;
    rcat_hal_ble_peer_allow_pairing(pairing_open);
}

uint32_t comm_pairing_left(uint32_t now_ms)
{
    return pairing_open ? pairing_until - now_ms : 0;
}

/* A command for others (others.h): from someone on the server, for this
 * board, or from the wearer, to send over direct comms. */
static void receive_command(const uint8_t *msg, size_t len)
{
    if (len < 3)
    {
        return;
    }
    if (msg[1] & COMMAND_FROM_SERVER)
    {
        size_t n = msg[2];
        if (3 + n > len || n >= COMM_NAME_MAX)
        {
            return;
        }
        char from[COMM_NAME_MAX];
        memcpy(from, msg + 3, n);
        from[n] = '\0';
        others_receive(COMM_TALK_SERVER, from, msg + 3 + n, len - 3 - n);
    }
    else
    {
        int count = msg[2];
        if (count > DIRECT_COMMAND_TARGETS || 3 + 4 * (size_t)count > len)
        {
            return;
        }
        uint32_t targets[DIRECT_COMMAND_TARGETS];
        for (int i = 0; i < count; i++)
        {
            const uint8_t *t = msg + 3 + 4 * i;
            targets[i] = t[0] | (t[1] << 8) | (t[2] << 16) | ((uint32_t)t[3] << 24);
        }
        size_t at = 3 + 4 * (size_t)count;
        direct_send_command(targets, count, msg + at, len - at);
    }
}

/* Who talking goes to, as the app picks (0x13). */
static void receive_talk_to(const uint8_t *msg, size_t len)
{
    if (len < 3 || msg[1] >= COMM_TO_COUNT)
    {
        return;
    }
    target_t t = { .to = (comm_to_t)msg[1], .on_server = (msg[2] & TALK_TO_ON_SERVER) != 0 };
    size_t at = 3;
    if (t.to == COMM_TO_PERSON)
    {
        if (len < at + OTHERS_KEY_LEN)
        {
            return;
        }
        memcpy(t.key, msg + at, OTHERS_KEY_LEN);
        at += OTHERS_KEY_LEN;
    }
    copy_name(t.name, msg + at, len - at);
    set_target(&t);
    // A channel's kept for the next startup
    comm_transport_t channel = t.to == COMM_TO_DIRECT ? COMM_TALK_DIRECT : COMM_TALK_SERVER;
    if (t.to != COMM_TO_PERSON && settings_get()->comm_talk_on != channel)
    {
        settings_set_comm_talk_on((uint8_t)channel);
    }
}

/* The pairs' keys, for talking to one alone over direct comms (0x14). */
static void receive_pairs(const uint8_t *msg, size_t len)
{
    if (msg[1] & PAIRS_FIRST)
    {
        direct_clear_pairs();
    }
    for (size_t at = 2; at + PAIR_ENTRY <= len; at += PAIR_ENTRY)
    {
        direct_add_pair(msg + at, msg + at + OTHERS_KEY_LEN);
    }
}

/* A piece of the firmware from the app (0x0E): see updater.h. */
static void receive_update(const uint8_t *msg, size_t len)
{
    uint8_t flags = msg[1];
    update_result_t result = UPDATE_OK;
    bool ack = (flags & (UPDATE_START | UPDATE_END | UPDATE_ACK)) != 0;
    if (flags & UPDATE_START)
    {
        // The length, then "<board>\n<version>", the version optional
        char text[96];
        uint32_t length = 0;
        size_t n = len > 6 ? len - 6 : 0;
        n = n < sizeof(text) - 1 ? n : sizeof(text) - 1;
        if (len >= 6)
        {
            memcpy(&length, msg + 2, 4);
            memcpy(text, msg + 6, n);
        }
        text[n] = '\0';
        char *version = strchr(text, '\n');
        if (version != NULL)
        {
            *version++ = '\0';
        }
        result = len >= 6 ? updater_app_begin(length, text, version != NULL ? version : "") : UPDATE_TOO_BIG;
    }
    else if (flags & UPDATE_END)
    {
        result = updater_app_finish();
    }
    else if (len >= 6)
    {
        uint32_t offset;
        memcpy(&offset, msg + 2, 4);
        result = updater_app_write(offset, msg + 6, len - 6);
    }
    if (ack)
    {
        uint32_t got = (uint32_t)updater_app_received();
        uint8_t out[7] = { MSG_UPDATE,
                           (uint8_t)((flags & UPDATE_END ? UPDATE_DONE : 0) | (result == UPDATE_OK ? UPDATE_WELL : 0) |
                                     (updater_app_installing() ? UPDATE_INSTALLING : 0)),
                           (uint8_t)result, (uint8_t)got, (uint8_t)(got >> 8), (uint8_t)(got >> 16),
                           (uint8_t)(got >> 24) };
        send_retrying(out, sizeof(out));
    }
}

void comm_poll(uint32_t now_ms)
{
    others_poll(now_ms);

    // Shut pairing when its time's up, or once a phone's paired with a code
    static bool code_shown;
    if (pairing_open && rcat_hal_ble_peer_passkey() >= 0)
    {
        code_shown = true;
    }
    if (pairing_open && (!running || (int32_t)(pairing_until - now_ms) <= 0 ||
                         (code_shown && rcat_hal_ble_peer_connected())))
    {
        comm_allow_pairing(false, now_ms);
    }
    if (!pairing_open)
    {
        code_shown = false;
    }
    // Quiet while it sends, if that's chosen
    bool mute = running && sending && settings_get()->comm_mute_speaker;
    if (mute != speaker_muted)
    {
        speaker_muted = mute;
        speaker_set_muted(mute);
    }
    update_audio();
    if (!running || !rcat_hal_ble_peer_connected())
    {
        forget_phone();
        merge_hearing();
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
        else if (msg[0] == MSG_COMMAND)
        {
            receive_command(msg, len);
        }
        else if (msg[0] == MSG_MUTED && len >= 2)
        {
            others_set_muted((msg[1] & MUTED_FIRST) != 0, msg + 2, len - 2);
        }
        else if (msg[0] == MSG_IDENTITY && len >= 1 + OTHERS_KEY_LEN)
        {
            others_set_owner(msg + 1);
        }
        else if (msg[0] == MSG_BINDING && len >= 1 + OTHERS_SIG_LEN)
        {
            others_set_binding(msg + 1);
        }
        else if (msg[0] == MSG_UPDATE && len >= 2)
        {
            receive_update(msg, len);
        }
        else if (msg[0] == MSG_TALK_TO)
        {
            receive_talk_to(msg, len);
        }
        else if (msg[0] == MSG_PAIRS && len >= 2)
        {
            receive_pairs(msg, len);
        }
        else if (msg[0] == MSG_RECORD && len >= 3)
        {
            set_recording(msg[1] != 0, (msg[2] & RECORD_SPEAKER) != 0, (msg[2] & RECORD_BEEP) != 0);
        }
    }
    merge_hearing();
    update_result_t installed;
    if (updater_app_outcome(&installed))
    {
        // The install after the end's ack went wrong: say so, if the phone's still there
        uint32_t got = (uint32_t)updater_app_received();
        uint8_t out[7] = { MSG_UPDATE, UPDATE_DONE, (uint8_t)installed, (uint8_t)got, (uint8_t)(got >> 8),
                           (uint8_t)(got >> 16), (uint8_t)(got >> 24) };
        send_retrying(out, sizeof(out));
    }
    send_direct_peers(now_ms);
    send_direct_avatars(now_ms);
    send_answer();

    // The wearer's avatar, for direct comms to send the others, once it's here
    static const uint16_t *own_sent;
    static uint32_t own_changes;
    const uint16_t *own = comm_avatar(own_avatar);
    if (own != NULL && (own != own_sent || avatar_changes != own_changes))
    {
        own_sent = own;
        own_changes = avatar_changes;
        direct_set_avatar(own, avatar_size);
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

void comm_set_voice_effect(int preset)
{
}

void comm_talk_to_channel(comm_transport_t channel)
{
}

comm_to_t comm_talk_to(void)
{
    return COMM_TO_SERVER;
}

comm_to_t comm_talk_to_now(void)
{
    return COMM_TO_SERVER;
}

const char *comm_talk_to_name(void)
{
    return "";
}

bool comm_talk_heard(void)
{
    return false;
}

bool comm_talk_refused(void)
{
    return false;
}

comm_transport_t comm_talk_now(void)
{
    return COMM_TALK_SERVER;
}

bool comm_recording(void)
{
    return false;
}

int comm_voice_effect(void)
{
    return -1;
}

bool comm_phone_connected(void)
{
    return false;
}

void comm_heard_to_phone(comm_transport_t via, const char *from, const uint8_t *key, uint64_t counter,
                         comm_heard_t what, uint8_t scope, bool done, const uint8_t *data, size_t len)
{
}

void comm_copy_to_phone(const uint8_t *key, uint64_t counter, uint32_t broadcast, int8_t rssi, uint8_t hops,
                        uint8_t len)
{
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

const char *comm_app_os(void)
{
    return "";
}

void comm_allow_pairing(bool allow, uint32_t now_ms)
{
}

uint32_t comm_pairing_left(uint32_t now_ms)
{
    return 0;
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

int comm_hearing_transport(int index)
{
    return COMM_TALK_SERVER;
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
