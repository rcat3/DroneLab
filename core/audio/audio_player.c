/*
 * Plays sound files from storage through the board's speaker, in the
 * background, while the display carries on as normal.
 *
 * The playlist is every WAV, MP3 and FLAC file in the "sounds" folder,
 * sorted by name. Files are read and decoded as they play, on the board's
 * speaker task, so they can be any length. When a track ends, the player
 * moves on to the next one, plays the same one again, or stops (see
 * audio_repeat_t). A track that's played again starts straight after its
 * own end, so a sound effect can loop without a gap. MP3s loop without a
 * gap too if the encoder recorded how much silence it added to each end
 * (LAME and ffmpeg do); otherwise there's a short silence at the loop.
 *
 * The UI and the speaker task share very little: the UI posts a command
 * (play, pause or resume) and the speaker task carries it out the next time
 * it asks for sound. The speaker task publishes which track is playing.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "audio/audio_player.h"
#include "audio/speaker.h"

#if RCAT_HAVE_FILESYSTEM

#include <dirent.h>
#include <strings.h>
#include <sys/stat.h>

#include "audio/audio_decoders.h"
#include "opus.h"

#define SOUNDS_FOLDER       "sounds"
#define MAX_TRACKS          100
#define MAX_FOLDER_LEN      192
#define MAX_PATH_LEN        320

// Sent sounds' Opus is decoded at this rate: plenty for the small speaker,
// and lighter than 48 kHz.
#define OPUS_RATE           24000
#define OPUS_FRAME_MAX      (OPUS_RATE * 120 / 1000)    // the longest a packet can be

// Files are decoded this many frames at a time, at most.
#define SCRATCH_FRAMES      256
#define MAX_CHANNELS        8

typedef enum
{
    CMD_PLAY,
    CMD_CUE,
    CMD_PAUSE,
    CMD_RESUME,
    CMD_SEEK,
    CMD_CHIME,
    CMD_CHIME_STOP,
} command_t;

typedef enum
{
    DECODER_NONE,
    DECODER_WAV,
    DECODER_MP3,
    DECODER_FLAC,
    DECODER_OPUS,
} decoder_kind_t;

/* A sent sound's Opus packets, in memory (AUDIO_SENT_OPUS). */
typedef struct
{
    const uint8_t *data;
    size_t len;
    size_t at;              // the next packet's length byte
    int16_t pcm[OPUS_FRAME_MAX];
    int pcm_len, pcm_at;    // decoded from the last packet, and handed out
} opus_stream_t;

typedef struct
{
    decoder_kind_t kind;
    uint32_t sample_rate;
    uint32_t channels;
    union
    {
        drwav wav;
        drmp3 mp3;
        drflac *flac;
        opus_stream_t opus;
    } u;
} decoder_t;

static bool available;
static char folder[MAX_FOLDER_LEN];
static char *file_names[MAX_TRACKS];
static char *track_names[MAX_TRACKS];
static size_t track_count;      // the SD card's; the sent ones are after them

/* The sounds sent, the oldest first: changed by the speaker's task alone,
 * which takes them in from pending_add and deletes them from
 * pending_delete, so one's never freed while it plays. Their names and
 * serials are copied out for the UI, which reads them as they are. */
typedef struct
{
    uint8_t *data;
    size_t len;
    uint8_t kind;
    uint8_t hash[32];
    uint32_t serial;
    char name[AUDIO_SENT_NAME_LEN];
} sent_t;
static sent_t *sent[AUDIO_SENT_KEPT];
static char sent_names[AUDIO_SENT_KEPT][AUDIO_SENT_NAME_LEN];
static volatile uint32_t sent_serials[AUDIO_SENT_KEPT];
static volatile uint8_t sent_count;
static sent_t *pending_add;         // from the UI, swapped atomically
static uint32_t pending_delete;     // a serial, from the UI; 0 for none
static uint32_t next_serial = 1;
static uint32_t tracks_changes;     // by the speaker's task, read by anyone

/* Files saved to the card, or deleted, while it runs (audio_player_file_added
 * and audio_player_remove_file): queued by the UI, taken by the speaker's
 * task, in order. */
#define FILE_OPS            8
#define FILE_NAME_LEN       80
typedef struct
{
    char name[FILE_NAME_LEN];
    bool add;
} file_op_t;
static file_op_t file_ops[FILE_OPS];
static uint32_t file_ops_head;      // written by the UI
static uint32_t file_ops_tail;      // written by the speaker's task
static OpusDecoder *opus_decoder;   // made the first time, in PSRAM (it's over the internal RAM limit)

// Written by the UI, read by the speaker task. The command and its track are
// written first, then cmd_seq is bumped to post it.
static volatile uint8_t cmd;
static volatile uint16_t cmd_track;
static volatile uint32_t cmd_position_ms;
static uint32_t cmd_seq;
static volatile uint8_t volume = 50;
static volatile uint8_t repeat = AUDIO_REPEAT_ALL;

// Written by the speaker task (and by the UI when it posts a command, so it
// sees the change straight away), read by the UI.
static volatile bool playing;
static volatile uint16_t current;

// Written by the speaker task, read by the UI: how far into the track it is,
// and how long the track is, in frames at its sample rate (0 if unknown).
static volatile uint32_t progress_frames;
static volatile uint32_t length_frames;
static volatile uint32_t progress_rate;

// Speaker task state
static uint32_t seen_seq;
static bool active;             // playing, rather than paused or stopped
static uint16_t track;
static decoder_t *decoder;      // too big for the stack, and for internal RAM
static int16_t *scratch;
static uint32_t frames_this_track;
static uint64_t file_bytes;     // for estimating an MP3's length, if it doesn't say

// A chime (audio_player_chime) playing over what was there, which comes
// back once it's done, where it was, playing or not
static volatile bool chiming;   // read by the UI too (audio_player_chiming)
static uint16_t saved_track;
static bool saved_active;
static bool saved_open;         // the track was open, part way through
static uint32_t saved_frame;
static uint32_t saved_progress, saved_length, saved_rate;

/* ----- Decoding ----- */

static bool has_extension(const char *file_name, const char *ext)
{
    size_t len = strlen(file_name);
    size_t ext_len = strlen(ext);
    return len > ext_len && strcasecmp(file_name + len - ext_len, ext) == 0;
}

static bool is_sound_file(const char *file_name)
{
    // Skip hidden files, including the "._name" files macOS leaves on cards.
    return file_name[0] != '.'
        && (has_extension(file_name, ".wav")
            || has_extension(file_name, ".mp3")
            || has_extension(file_name, ".flac"));
}

static void decoder_close(void)
{
    switch (decoder->kind)
    {
        case DECODER_WAV:
            drwav_uninit(&decoder->u.wav);
            break;
        case DECODER_MP3:
            drmp3_uninit(&decoder->u.mp3);
            break;
        case DECODER_FLAC:
            drflac_close(decoder->u.flac);
            break;
        case DECODER_OPUS:
        case DECODER_NONE:
            break;
    }
    decoder->kind = DECODER_NONE;
    progress_frames = 0;
    length_frames = 0;
}

/* The track's length in frames, if the file says, or 0. */
static uint32_t decoder_length(void)
{
    uint64_t frames = 0;
    switch (decoder->kind)
    {
        case DECODER_WAV:
            frames = decoder->u.wav.totalPCMFrameCount;
            break;
        case DECODER_MP3:
        {
            // From the header LAME and ffmpeg write at the start, which
            // includes the silence they add to each end, that dr_mp3 skips.
            const drmp3 *mp3 = &decoder->u.mp3;
            uint64_t ends = (uint64_t)mp3->delayInPCMFrames + mp3->paddingInPCMFrames;
            if (mp3->totalPCMFrameCount != DRMP3_UINT64_MAX && mp3->totalPCMFrameCount > ends)
            {
                frames = mp3->totalPCMFrameCount - ends;
            }
            break;
        }
        case DECODER_FLAC:
            frames = decoder->u.flac->totalPCMFrameCount;
            break;
        case DECODER_OPUS:
        {
            const opus_stream_t *o = &decoder->u.opus;
            for (size_t at = 0; at < o->len && at + 1 + o->data[at] <= o->len; at += 1 + o->data[at])
            {
                int n = o->data[at] > 0 ? opus_packet_get_nb_samples(o->data + at + 1, o->data[at], OPUS_RATE) : 0;
                frames += n > 0 ? (uint64_t)n : 0;
            }
            break;
        }
        case DECODER_NONE:
            break;
    }
    if (track >= track_count && frames > (uint64_t)decoder->sample_rate * AUDIO_SENT_MAX_MS / 1000)
    {
        frames = (uint64_t)decoder->sample_rate * AUDIO_SENT_MAX_MS / 1000;     // a sent one's cut short
    }
    return frames > UINT32_MAX ? 0 : (uint32_t)frames;
}

/* For an MP3 that doesn't say how long it is: as far into the file as it's
 * decoded, against how much of the file that is. It needs a second or so to
 * settle. */
static uint32_t estimate_mp3_length(void)
{
    const drmp3 *mp3 = &decoder->u.mp3;
    uint64_t start = mp3->streamStartOffset;
    // dr_mp3 stops at any ID3v1 or APE tag at the end, which isn't audio
    uint64_t end = mp3->streamLength != DRMP3_UINT64_MAX ? mp3->streamLength : file_bytes;
    uint64_t decoded = mp3->streamCursor > mp3->dataSize ? mp3->streamCursor - mp3->dataSize : 0;
    // The bytes are counted a whole MP3 frame at a time, as each one's
    // decoded, so count the audio to the end of that frame too. Otherwise the
    // estimate jumps up and down as each frame's handed out.
    uint64_t frames = (uint64_t)frames_this_track + mp3->pcmFramesRemainingInMP3Frame;
    if (frames_this_track < decoder->sample_rate || end <= start || decoded <= start)
    {
        return 0;
    }
    frames = frames * (end - start) / (decoded - start);
    return frames > UINT32_MAX ? 0 : (uint32_t)frames;
}

static size_t total_tracks(void)
{
    return track_count + sent_count;
}

/* A sent one, from memory. */
static bool sent_open(const sent_t *s)
{
    const uint8_t *d = s->data;
    size_t len = s->len;
    if (s->kind == AUDIO_SENT_OPUS)
    {
        if (opus_decoder == NULL)
        {
            opus_decoder = malloc((size_t)opus_decoder_get_size(1));
            if (opus_decoder == NULL || opus_decoder_init(opus_decoder, OPUS_RATE, 1) != OPUS_OK)
            {
                free(opus_decoder);
                opus_decoder = NULL;
                return false;
            }
        }
        opus_decoder_ctl(opus_decoder, OPUS_RESET_STATE);
        opus_stream_t *o = &decoder->u.opus;
        o->data = d;
        o->len = len;
        o->at = 0;
        o->pcm_len = o->pcm_at = 0;
        decoder->kind = DECODER_OPUS;
        decoder->sample_rate = OPUS_RATE;
        decoder->channels = 1;
    }
    // A file as it is, by what it starts with
    else if (len >= 4 && memcmp(d, "RIFF", 4) == 0 && drwav_init_memory(&decoder->u.wav, d, len, NULL))
    {
        decoder->kind = DECODER_WAV;
        decoder->sample_rate = decoder->u.wav.sampleRate;
        decoder->channels = decoder->u.wav.channels;
    }
    else if (len >= 4 && memcmp(d, "fLaC", 4) == 0 && (decoder->u.flac = drflac_open_memory(d, len, NULL)) != NULL)
    {
        decoder->kind = DECODER_FLAC;
        decoder->sample_rate = decoder->u.flac->sampleRate;
        decoder->channels = decoder->u.flac->channels;
    }
    else if (drmp3_init_memory(&decoder->u.mp3, d, len, NULL))
    {
        decoder->kind = DECODER_MP3;
        decoder->sample_rate = decoder->u.mp3.sampleRate;
        decoder->channels = decoder->u.mp3.channels;
    }
    else
    {
        return false;
    }
    file_bytes = len;
    return true;
}

static bool decoder_open(size_t index)
{
    char path[MAX_PATH_LEN];
    if (index >= track_count)
    {
        const sent_t *s = index < total_tracks() ? sent[index - track_count] : NULL;
        if (s == NULL || !sent_open(s))
        {
            printf("sound: can't play the one sent\n");
            return false;
        }
        if (decoder->sample_rate == 0 || decoder->channels == 0 || decoder->channels > MAX_CHANNELS)
        {
            decoder_close();
            return false;
        }
        progress_rate = decoder->sample_rate;
        progress_frames = 0;
        length_frames = decoder_length();
        printf("sound: playing %s\n", s->name);
        return true;
    }
    const char *name = file_names[index];
    if (snprintf(path, sizeof(path), "%s/%s", folder, name) >= (int)sizeof(path))
    {
        return false;
    }

    if (has_extension(name, ".wav") && drwav_init_file(&decoder->u.wav, path, NULL))
    {
        decoder->kind = DECODER_WAV;
        decoder->sample_rate = decoder->u.wav.sampleRate;
        decoder->channels = decoder->u.wav.channels;
    }
    else if (has_extension(name, ".mp3") && drmp3_init_file(&decoder->u.mp3, path, NULL))
    {
        decoder->kind = DECODER_MP3;
        decoder->sample_rate = decoder->u.mp3.sampleRate;
        decoder->channels = decoder->u.mp3.channels;
    }
    else if (has_extension(name, ".flac") && (decoder->u.flac = drflac_open_file(path, NULL)) != NULL)
    {
        decoder->kind = DECODER_FLAC;
        decoder->sample_rate = decoder->u.flac->sampleRate;
        decoder->channels = decoder->u.flac->channels;
    }
    else
    {
        printf("sound: can't play %s\n", name);
        return false;
    }

    if (decoder->sample_rate == 0 || decoder->channels == 0 || decoder->channels > MAX_CHANNELS)
    {
        printf("sound: can't play %s (%lu channels at %lu Hz)\n", name,
               (unsigned long)decoder->channels, (unsigned long)decoder->sample_rate);
        decoder_close();
        return false;
    }
    struct stat st;
    file_bytes = stat(path, &st) == 0 ? (uint64_t)st.st_size : 0;
    progress_rate = decoder->sample_rate;
    progress_frames = 0;
    length_frames = decoder_length();
    printf("sound: playing %s\n", name);
    return true;
}

static size_t opus_read(int16_t *dest, size_t frames);

/* Move the open track to a frame. Returns false if it can't. */
static bool decoder_seek(uint32_t frame)
{
    switch (decoder->kind)
    {
        case DECODER_WAV:
            return drwav_seek_to_pcm_frame(&decoder->u.wav, frame);
        case DECODER_FLAC:
            return drflac_seek_to_pcm_frame(decoder->u.flac, frame);
        case DECODER_MP3:
        {
            // dr_mp3 can only find a frame exactly by decoding from the
            // start, which takes seconds. Instead, go to the same share of
            // the file's length, by giving it a seek point there: it starts
            // decoding at the next MP3 frame it finds.
            drmp3 *mp3 = &decoder->u.mp3;
            uint64_t start = mp3->streamStartOffset;
            uint64_t end = mp3->streamLength != DRMP3_UINT64_MAX ? mp3->streamLength : file_bytes;
            uint32_t length = length_frames;
            if (frame == 0)
            {
                return drmp3_seek_to_pcm_frame(mp3, 0);
            }
            if (length == 0 || end <= start)
            {
                return false;
            }
            drmp3_seek_point point = {
                .seekPosInBytes = start + (end - start) * frame / length,
                .pcmFrameIndex = frame + mp3->delayInPCMFrames,
                .mp3FramesToDiscard = 1,    // fills the decoder's bit reservoir
                .pcmFramesToDiscard = 0,
            };
            bool ok = drmp3_bind_seek_table(mp3, 1, &point)
                      && drmp3_seek_to_pcm_frame(mp3, point.pcmFrameIndex);
            drmp3_bind_seek_table(mp3, 0, NULL);
            return ok;
        }
        case DECODER_OPUS:
        {
            // From the start, packet by packet, to the one it's in: they're
            // in memory, and a sent one's short
            opus_stream_t *o = &decoder->u.opus;
            opus_decoder_ctl(opus_decoder, OPUS_RESET_STATE);
            o->at = 0;
            o->pcm_len = o->pcm_at = 0;
            uint32_t skipped = 0;
            while (o->at < o->len && o->at + 1 + o->data[o->at] <= o->len)
            {
                size_t n = o->data[o->at];
                int frames = n > 0 ? opus_packet_get_nb_samples(o->data + o->at + 1, (opus_int32)n, OPUS_RATE) : 0;
                if (frames > 0 && skipped + (uint32_t)frames > frame)
                {
                    break;
                }
                skipped += frames > 0 ? (uint32_t)frames : 0;
                o->at += 1 + n;
            }
            // Decoded from there, the part before the frame left out
            for (uint32_t extra = frame - skipped; extra > 0;)
            {
                size_t got = opus_read(scratch, extra < SCRATCH_FRAMES ? extra : SCRATCH_FRAMES);
                if (got == 0)
                {
                    break;
                }
                extra -= (uint32_t)got;
            }
            return true;
        }
        case DECODER_NONE:
            break;
    }
    return false;
}

/* Up to frames frames of a sent sound's Opus, mono. */
static size_t opus_read(int16_t *dest, size_t frames)
{
    opus_stream_t *o = &decoder->u.opus;
    size_t got = 0;
    while (got < frames)
    {
        if (o->pcm_at == o->pcm_len)
        {
            if (o->at >= o->len)
            {
                break;      // the end
            }
            size_t n = o->data[o->at];
            const uint8_t *pkt = o->data + o->at + 1;
            o->at += 1 + n;
            if (o->at > o->len)
            {
                break;      // cut short: the end
            }
            int r = n > 0 ? opus_decode(opus_decoder, pkt, (opus_int32)n, o->pcm, OPUS_FRAME_MAX, 0) : 0;
            o->pcm_len = r > 0 ? r : 0;
            o->pcm_at = 0;
            continue;
        }
        size_t take = (size_t)(o->pcm_len - o->pcm_at);
        take = take < frames - got ? take : frames - got;
        memcpy(dest + got, o->pcm + o->pcm_at, take * sizeof(int16_t));
        o->pcm_at += (int)take;
        got += take;
    }
    return got;
}

/* Decode up to max_frames frames as stereo. Returns 0 at the end. */
static size_t decoder_read(int16_t *out, size_t max_frames)
{
    size_t frames = (max_frames < SCRATCH_FRAMES) ? max_frames : SCRATCH_FRAMES;
    uint32_t channels = decoder->channels;
    int16_t *dest = (channels == 2) ? out : scratch;
    size_t got = 0;

    switch (decoder->kind)
    {
        case DECODER_WAV:
            got = drwav_read_pcm_frames_s16(&decoder->u.wav, frames, dest);
            break;
        case DECODER_MP3:
            got = drmp3_read_pcm_frames_s16(&decoder->u.mp3, frames, dest);
            break;
        case DECODER_FLAC:
            got = drflac_read_pcm_frames_s16(decoder->u.flac, frames, dest);
            break;
        case DECODER_OPUS:
            got = opus_read(dest, frames);
            break;
        case DECODER_NONE:
            break;
    }

    // Mono plays on both sides. With more than two channels, the first two
    // are the front left and right.
    if (channels == 1)
    {
        for (size_t i = 0; i < got; i++)
        {
            out[2 * i] = out[2 * i + 1] = scratch[i];
        }
    }
    else if (channels > 2)
    {
        for (size_t i = 0; i < got; i++)
        {
            out[2 * i] = scratch[channels * i];
            out[2 * i + 1] = scratch[channels * i + 1];
        }
    }
    return got;
}

/* ----- Speaker task ----- */

static void publish(void)
{
    // A chime's not shown: what it plays over is
    current = chiming ? saved_track : track;
    playing = chiming ? saved_active : active;
}

/* A chime's done, or couldn't play: back to what was there, where it was. */
static void end_chime(void)
{
    decoder_close();
    chiming = false;
    track = saved_track;
    active = saved_active;
    if (saved_open && decoder_open(track))
    {
        if (saved_frame > 0 && decoder_seek(saved_frame))
        {
            frames_this_track = saved_frame;
            progress_frames = saved_frame;
        }
        else
        {
            frames_this_track = 0;
        }
    }
    else
    {
        progress_frames = saved_progress;
        length_frames = saved_length;
        progress_rate = saved_rate;
    }
    publish();
}

static void stop(void)
{
    decoder_close();
    active = false;
    publish();
}

/* Play a track once, over what's there, which comes back after. */
static void start_chime(size_t index)
{
    if (!chiming)
    {
        saved_track = track;
        saved_active = active;
        saved_open = decoder->kind != DECODER_NONE;
        saved_frame = frames_this_track;
        saved_progress = progress_frames;
        saved_length = length_frames;
        saved_rate = progress_rate;
    }
    decoder_close();
    track = (uint16_t)((index < total_tracks()) ? index : 0);
    active = true;
    chiming = true;
}

/* ----- Sent ones, on the speaker's task ----- */

static void copy_out_sent(void)
{
    for (int i = 0; i < AUDIO_SENT_KEPT; i++)
    {
        snprintf(sent_names[i], sizeof(sent_names[i]), "%s", i < sent_count ? sent[i]->name : "");
        sent_serials[i] = i < sent_count ? sent[i]->serial : 0;
    }
}

static void free_sent(sent_t *s)
{
    free(s->data);
    free(s);
}

/* Take away the one in slot i, stopping it first if it's playing, or what
 * it's under; the tracks after it move down one. */
static void remove_sent(int i)
{
    uint16_t index = (uint16_t)(track_count + i);
    if (chiming && saved_track == index)
    {
        // What the chime's over is going: nothing to go back to
        saved_track = 0;
        saved_active = false;
        saved_open = false;
        saved_progress = saved_length = 0;
    }
    if (track == index)
    {
        if (chiming)
        {
            end_chime();
        }
        else
        {
            decoder_close();
            active = false;
            track = 0;
        }
    }
    free_sent(sent[i]);
    memmove(&sent[i], &sent[i + 1], (size_t)(sent_count - i - 1) * sizeof(sent[0]));
    sent[--sent_count] = NULL;
    if (track > index)
    {
        track--;
    }
    if (saved_track > index)
    {
        saved_track--;
    }
}

/* A file saved to the card: a track after the card's others, the sent ones'
 * indexes moving up one. Whatever plays carries on. */
static void add_file_track(const char *name)
{
    if (track_count >= MAX_TRACKS || !is_sound_file(name))
    {
        return;
    }
    for (size_t i = 0; i < track_count; i++)
    {
        if (strcasecmp(file_names[i], name) == 0)
        {
            return;     // had it
        }
    }
    char *file = strdup(name);
    char *shown = strdup(name);
    if (file == NULL || shown == NULL)
    {
        free(file);
        free(shown);
        return;
    }
    *strrchr(shown, '.') = '\0';
    file_names[track_count] = file;
    track_names[track_count] = shown;
    if (track >= track_count)
    {
        track++;
    }
    if (saved_track >= track_count)
    {
        saved_track++;
    }
    track_count++;
    printf("sound: added %s\n", name);
}

/* A file deleted from the card: stopped first if it plays, or what it's
 * under, then the file itself, with the tracks after it moving down one. */
static void remove_file_track(const char *name)
{
    char path[MAX_PATH_LEN];
    for (size_t i = 0; i < track_count; i++)
    {
        if (strcasecmp(file_names[i], name) != 0)
        {
            continue;
        }
        uint16_t index = (uint16_t)i;
        if (chiming && saved_track == index)
        {
            saved_track = 0;
            saved_active = false;
            saved_open = false;
            saved_progress = saved_length = 0;
        }
        if (track == index)
        {
            if (chiming)
            {
                end_chime();
            }
            else
            {
                decoder_close();
                active = false;
            }
        }
        if (snprintf(path, sizeof(path), "%s/%s", folder, file_names[i]) < (int)sizeof(path))
        {
            remove(path);
        }
        free(file_names[i]);
        free(track_names[i]);
        memmove(&file_names[i], &file_names[i + 1], (track_count - i - 1) * sizeof(file_names[0]));
        memmove(&track_names[i], &track_names[i + 1], (track_count - i - 1) * sizeof(track_names[0]));
        track_count--;
        if (track > index)
        {
            track--;
        }
        if (track >= total_tracks())
        {
            track = 0;
        }
        if (saved_track > index)
        {
            saved_track--;
        }
        return;
    }
    // Not a track (the list was full, say): the file's still to go
    if (snprintf(path, sizeof(path), "%s/%s", folder, name) < (int)sizeof(path))
    {
        remove(path);
    }
}

static bool take_file_ops(void)
{
    bool any = false;
    while (file_ops_tail != __atomic_load_n(&file_ops_head, __ATOMIC_ACQUIRE))
    {
        const file_op_t *op = &file_ops[file_ops_tail % FILE_OPS];
        if (op->add)
        {
            add_file_track(op->name);
        }
        else
        {
            remove_file_track(op->name);
        }
        __atomic_store_n(&file_ops_tail, file_ops_tail + 1, __ATOMIC_RELEASE);
        any = true;
    }
    return any;
}

/* What the UI's sent or deleted since. */
static void take_sent(void)
{
    bool files = take_file_ops();
    if (files)
    {
        publish();
        __atomic_add_fetch(&tracks_changes, 1, __ATOMIC_RELEASE);
    }
    uint32_t serial = __atomic_exchange_n(&pending_delete, 0, __ATOMIC_ACQ_REL);
    sent_t *s = __atomic_exchange_n(&pending_add, NULL, __ATOMIC_ACQ_REL);
    if (serial == 0 && s == NULL)
    {
        return;
    }
    for (int i = 0; serial != 0 && i < sent_count; i++)
    {
        if (sent[i]->serial == serial)
        {
            remove_sent(i);
            break;
        }
    }
    if (s != NULL)
    {
        int at = -1;
        for (int i = 0; i < sent_count; i++)
        {
            if (memcmp(sent[i]->hash, s->hash, sizeof(s->hash)) == 0)
            {
                at = i;     // had it already: played again
                break;
            }
        }
        if (at >= 0)
        {
            free_sent(s);
        }
        else
        {
            if (sent_count == AUDIO_SENT_KEPT)
            {
                remove_sent(0);
            }
            at = sent_count;
            sent[sent_count++] = s;
        }
        start_chime(track_count + (size_t)at);
    }
    copy_out_sent();
    __atomic_add_fetch(&tracks_changes, 1, __ATOMIC_RELEASE);
    publish();
}

bool audio_player_sent_playing(void)
{
    if (decoder == NULL)
    {
        return false;
    }
    take_sent();
    return chiming && track >= track_count;
}

static void handle_commands(void)
{
    uint32_t seq = __atomic_load_n(&cmd_seq, __ATOMIC_ACQUIRE);
    if (seq == seen_seq)
    {
        return;
    }
    seen_seq = seq;

    // Anything else asked for ends a chime first, back to what was there
    if (chiming && cmd != CMD_CHIME && cmd != CMD_CHIME_STOP)
    {
        end_chime();
    }
    switch (cmd)
    {
        case CMD_CHIME_STOP:
            if (chiming)
            {
                end_chime();
            }
            break;
        case CMD_CHIME:
            start_chime(cmd_track);
            break;
        case CMD_PLAY:
            decoder_close();
            track = (cmd_track < total_tracks()) ? cmd_track : 0;
            active = true;
            break;
        case CMD_CUE:
            decoder_close();
            track = (cmd_track < total_tracks()) ? cmd_track : 0;
            active = false;
            break;
        case CMD_PAUSE:
            active = false;
            break;
        case CMD_RESUME:
            active = true;     // from where it was paused, or the start if it had stopped
            break;
        case CMD_SEEK:
        {
            if (decoder->kind == DECODER_NONE)
            {
                if (!decoder_open(track))
                {
                    break;
                }
                frames_this_track = 0;
            }
            uint32_t frame = (uint32_t)((uint64_t)cmd_position_ms * decoder->sample_rate / 1000);
            uint32_t length = length_frames;
            if (length > 0 && frame >= length)
            {
                frame = length - 1;
            }
            if (decoder_seek(frame))
            {
                frames_this_track = frame;
                progress_frames = frame;
            }
            break;
        }
    }
    publish();
}

/* Volume in percent to a gain out of 65536. Loudness goes roughly with the
 * square of the gain, so the slider feels even. */
static int32_t volume_gain(void)
{
    int32_t v = volume;
    return v * v * 65536 / (100 * 100);
}

size_t audio_player_fill(int16_t *frames, size_t max_frames, uint32_t *sample_rate)
{
    if (decoder == NULL)
    {
        return 0;
    }
    handle_commands();

    size_t done = 0;
    uint32_t block_rate = 0;
    size_t failures = 0;

    while (active && done < max_frames)
    {
        if (decoder->kind == DECODER_NONE)
        {
            if (!decoder_open(track))
            {
                if (chiming)
                {
                    end_chime();
                    continue;
                }
                // Skip files that can't be played, unless they all fail.
                if (repeat != AUDIO_REPEAT_ALL || ++failures >= total_tracks())
                {
                    stop();
                    break;
                }
                track = (track + 1) % total_tracks();
                publish();
                continue;
            }
            frames_this_track = 0;
        }

        // Each block is at one sample rate. A track at a different rate
        // starts in the next block.
        if (block_rate == 0)
        {
            block_rate = decoder->sample_rate;
        }
        else if (decoder->sample_rate != block_rate)
        {
            break;
        }

        // A sent one stops at AUDIO_SENT_MAX_MS, however long it is
        size_t want = max_frames - done;
        if (track >= track_count)
        {
            uint32_t most = (uint32_t)((uint64_t)decoder->sample_rate * AUDIO_SENT_MAX_MS / 1000);
            uint32_t left = frames_this_track < most ? most - frames_this_track : 0;
            want = want < left ? want : left;
        }
        size_t got = want > 0 ? decoder_read(frames + 2 * done, want) : 0;
        if (got > 0)
        {
            done += got;
            frames_this_track += got;
            failures = 0;
            // A variable bitrate MP3's estimate still wanders a little, so
            // it's only updated once a second, with the time played, rather
            // than flickering in between.
            uint32_t second = decoder->sample_rate;
            if (chiming)
            {
                continue;       // the player shows what it's playing over
            }
            if (decoder->kind == DECODER_MP3 && decoder_length() == 0
                && (length_frames == 0 || frames_this_track / second != progress_frames / second))
            {
                length_frames = estimate_mp3_length();
            }
            progress_frames = frames_this_track;
            continue;
        }

        // The end of the track. A chime's: back to what was there.
        if (chiming)
        {
            end_chime();
            continue;
        }
        // Stop if tracks keep ending without playing anything, rather than
        // opening them over and over.
        decoder_close();
        if (frames_this_track == 0 && ++failures > total_tracks())
        {
            stop();
            break;
        }
        if (repeat == AUDIO_REPEAT_OFF)
        {
            stop();
            break;
        }
        if (repeat == AUDIO_REPEAT_ALL)
        {
            track = (track + 1) % total_tracks();
        }
        publish();
    }

    if (done > 0)
    {
        int32_t gain = volume_gain();
        for (size_t i = 0; i < 2 * done; i++)
        {
            frames[i] = (int16_t)((frames[i] * gain) >> 16);
        }
        *sample_rate = block_rate;
    }
    return done;
}

/* ----- Public ----- */

static int compare_names(const void *a, const void *b)
{
    return strcasecmp(*(const char * const *)a, *(const char * const *)b);
}

static void find_tracks(const char *storage_path)
{
    if (snprintf(folder, sizeof(folder), "%s/" SOUNDS_FOLDER, storage_path) >= (int)sizeof(folder))
    {
        return;
    }
    DIR *dir = opendir(folder);
    if (dir == NULL)
    {
        return;
    }

    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL && track_count < MAX_TRACKS)
    {
        if (entry->d_type != DT_DIR && is_sound_file(entry->d_name))
        {
            file_names[track_count++] = strdup(entry->d_name);
        }
    }
    closedir(dir);
    qsort(file_names, track_count, sizeof(file_names[0]), compare_names);

    for (size_t i = 0; i < track_count; i++)
    {
        track_names[i] = strdup(file_names[i]);
        *strrchr(track_names[i], '.') = '\0';
        printf("sound: found %s\n", file_names[i]);
    }
}

bool audio_player_init(const char *storage_path)
{
    if (storage_path != NULL)
    {
        find_tracks(storage_path);
    }

    decoder = calloc(1, sizeof(*decoder));
    scratch = malloc(SCRATCH_FRAMES * MAX_CHANNELS * sizeof(int16_t));
    if (decoder == NULL || scratch == NULL)
    {
        printf("sound: not enough memory\n");
        return false;
    }

    available = speaker_start();
    return available;
}

size_t audio_player_track_count(void)
{
    return total_tracks();
}

const char *audio_player_track_name(size_t index)
{
    return index < track_count ? track_names[index] : index < total_tracks() ? sent_names[index - track_count] : "";
}

static bool queue_file_op(const char *file_name, bool add)
{
    uint32_t head = file_ops_head;
    if (!available || strlen(file_name) >= FILE_NAME_LEN
        || head - __atomic_load_n(&file_ops_tail, __ATOMIC_ACQUIRE) >= FILE_OPS)
    {
        return false;
    }
    file_op_t *op = &file_ops[head % FILE_OPS];
    snprintf(op->name, sizeof(op->name), "%s", file_name);
    op->add = add;
    __atomic_store_n(&file_ops_head, head + 1, __ATOMIC_RELEASE);
    return true;
}

bool audio_player_file_added(const char *file_name)
{
    return queue_file_op(file_name, true);
}

bool audio_player_remove_file(const char *file_name)
{
    return queue_file_op(file_name, false);
}

size_t audio_player_file_room(void)
{
    return track_count < MAX_TRACKS ? MAX_TRACKS - track_count : 0;
}

bool audio_player_is_sent(size_t index)
{
    return index >= track_count && index < total_tracks();
}

size_t audio_player_sent_count(void)
{
    return sent_count;
}

uint32_t audio_player_tracks_changes(void)
{
    return __atomic_load_n(&tracks_changes, __ATOMIC_ACQUIRE);
}

bool audio_player_add_sent(uint8_t *data, size_t len, uint8_t kind, const uint8_t hash[32], const char *name)
{
    sent_t *s = available && data != NULL ? calloc(1, sizeof(*s)) : NULL;
    if (s == NULL)
    {
        free(data);
        return false;
    }
    s->data = data;
    s->len = len;
    s->kind = kind;
    memcpy(s->hash, hash, sizeof(s->hash));
    s->serial = next_serial++;
    snprintf(s->name, sizeof(s->name), "%s", name);
    // One the speaker's task hasn't taken yet gives way to this
    sent_t *old = __atomic_exchange_n(&pending_add, s, __ATOMIC_ACQ_REL);
    if (old != NULL)
    {
        free_sent(old);
    }
    return true;
}

void audio_player_delete_sent(size_t index)
{
    if (audio_player_is_sent(index))
    {
        uint32_t serial = sent_serials[index - track_count];
        if (serial != 0)
        {
            __atomic_store_n(&pending_delete, serial, __ATOMIC_RELEASE);
        }
    }
}

static void post(command_t command, size_t index)
{
    cmd = command;
    cmd_track = (uint16_t)index;
    __atomic_add_fetch(&cmd_seq, 1, __ATOMIC_RELEASE);
}

void audio_player_play(size_t index)
{
    if (total_tracks() == 0)
    {
        return;
    }
    current = (uint16_t)(index % total_tracks());
    playing = true;
    post(CMD_PLAY, current);
}

void audio_player_cue(size_t index)
{
    if (total_tracks() == 0)
    {
        return;
    }
    current = (uint16_t)(index % total_tracks());
    playing = false;
    post(CMD_CUE, current);
}

void audio_player_chime(size_t index)
{
    if (track_count == 0 || index >= track_count)
    {
        return;
    }
    post(CMD_CHIME, index);
}

void audio_player_chime_stop(void)
{
    post(CMD_CHIME_STOP, 0);
}

bool audio_player_chiming(void)
{
    return chiming;
}

void audio_player_seek(uint32_t position_ms)
{
    if (total_tracks() == 0)
    {
        return;
    }
    cmd_position_ms = position_ms;
    post(CMD_SEEK, current);
}

void audio_player_pause(void)
{
    playing = false;
    post(CMD_PAUSE, 0);
}

void audio_player_resume(void)
{
    if (total_tracks() == 0)
    {
        return;
    }
    playing = true;
    post(CMD_RESUME, 0);
}

void audio_player_set_volume(uint8_t percent)
{
    volume = (percent > 100) ? 100 : percent;
}

void audio_player_set_repeat(audio_repeat_t r)
{
    repeat = (r < AUDIO_REPEAT_COUNT) ? r : AUDIO_REPEAT_ALL;
}

#else   // no filesystem, so nothing to play

bool audio_player_init(const char *storage_path)
{
    return false;
}

bool audio_player_file_added(const char *file_name)
{
    return false;
}

bool audio_player_remove_file(const char *file_name)
{
    return false;
}

size_t audio_player_file_room(void)
{
    return 0;
}

size_t audio_player_track_count(void)
{
    return 0;
}

const char *audio_player_track_name(size_t index)
{
    return "";
}

size_t audio_player_fill(int16_t *frames, size_t max_frames, uint32_t *sample_rate)
{
    return 0;
}

void audio_player_play(size_t index) {}
bool audio_player_add_sent(uint8_t *data, size_t len, uint8_t kind, const uint8_t hash[32], const char *name)
{
    free(data);
    return false;
}
bool audio_player_is_sent(size_t index)
{
    return false;
}
void audio_player_delete_sent(size_t index) {}
size_t audio_player_sent_count(void)
{
    return 0;
}
uint32_t audio_player_tracks_changes(void)
{
    return 0;
}
bool audio_player_sent_playing(void)
{
    return false;
}
void audio_player_cue(size_t index) {}
void audio_player_chime(size_t index) {}
void audio_player_chime_stop(void) {}
bool audio_player_chiming(void)
{
    return false;
}
void audio_player_pause(void) {}
void audio_player_seek(uint32_t position_ms) {}
void audio_player_resume(void) {}
void audio_player_set_volume(uint8_t percent) {}
void audio_player_set_repeat(audio_repeat_t r) {}

static const bool available = false;
static const bool playing = false;
static const uint16_t current = 0;

#endif

bool audio_player_available(void)
{
    return available;
}

bool audio_player_is_playing(void)
{
    return playing;
}

size_t audio_player_current(void)
{
    return current;
}

void audio_player_progress(uint32_t *position_ms, uint32_t *length_ms)
{
#if RCAT_HAVE_FILESYSTEM
    uint32_t rate = progress_rate;
    uint32_t position = progress_frames;
    uint32_t length = length_frames;
    if (rate == 0)
    {
        *position_ms = 0;
        *length_ms = 0;
        return;
    }
    if (length != 0 && position > length)
    {
        length = position;      // an estimate that came out short
    }
    *position_ms = (uint32_t)((uint64_t)position * 1000 / rate);
    *length_ms = (uint32_t)((uint64_t)length * 1000 / rate);
#else
    *position_ms = 0;
    *length_ms = 0;
#endif
}
