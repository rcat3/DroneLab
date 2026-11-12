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

#define SOUNDS_FOLDER       "sounds"
#define MAX_TRACKS          100
#define MAX_FOLDER_LEN      64
#define MAX_PATH_LEN        320

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
} command_t;

typedef enum
{
    DECODER_NONE,
    DECODER_WAV,
    DECODER_MP3,
    DECODER_FLAC,
} decoder_kind_t;

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
    } u;
} decoder_t;

static bool available;
static char folder[MAX_FOLDER_LEN];
static char *file_names[MAX_TRACKS];
static char *track_names[MAX_TRACKS];
static size_t track_count;

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
        case DECODER_NONE:
            break;
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

static bool decoder_open(size_t index)
{
    char path[MAX_PATH_LEN];
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
        case DECODER_NONE:
            break;
    }
    return false;
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
    current = track;
    playing = active;
}

static void stop(void)
{
    decoder_close();
    active = false;
    publish();
}

static void handle_commands(void)
{
    uint32_t seq = __atomic_load_n(&cmd_seq, __ATOMIC_ACQUIRE);
    if (seq == seen_seq)
    {
        return;
    }
    seen_seq = seq;

    switch (cmd)
    {
        case CMD_PLAY:
            decoder_close();
            track = (cmd_track < track_count) ? cmd_track : 0;
            active = true;
            break;
        case CMD_CUE:
            decoder_close();
            track = (cmd_track < track_count) ? cmd_track : 0;
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
                // Skip files that can't be played, unless they all fail.
                if (repeat != AUDIO_REPEAT_ALL || ++failures >= track_count)
                {
                    stop();
                    break;
                }
                track = (track + 1) % track_count;
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

        size_t got = decoder_read(frames + 2 * done, max_frames - done);
        if (got > 0)
        {
            done += got;
            frames_this_track += got;
            failures = 0;
            // A variable bitrate MP3's estimate still wanders a little, so
            // it's only updated once a second, with the time played, rather
            // than flickering in between.
            uint32_t second = decoder->sample_rate;
            if (decoder->kind == DECODER_MP3 && decoder_length() == 0
                && (length_frames == 0 || frames_this_track / second != progress_frames / second))
            {
                length_frames = estimate_mp3_length();
            }
            progress_frames = frames_this_track;
            continue;
        }

        // The end of the track. Stop if tracks keep ending without playing
        // anything, rather than opening them over and over.
        decoder_close();
        if (frames_this_track == 0 && ++failures > track_count)
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
            track = (track + 1) % track_count;
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
    return track_count;
}

const char *audio_player_track_name(size_t index)
{
    return (index < track_count) ? track_names[index] : "";
}

static void post(command_t command, size_t index)
{
    cmd = command;
    cmd_track = (uint16_t)index;
    __atomic_add_fetch(&cmd_seq, 1, __ATOMIC_RELEASE);
}

void audio_player_play(size_t index)
{
    if (track_count == 0)
    {
        return;
    }
    current = (uint16_t)(index % track_count);
    playing = true;
    post(CMD_PLAY, current);
}

void audio_player_cue(size_t index)
{
    if (track_count == 0)
    {
        return;
    }
    current = (uint16_t)(index % track_count);
    playing = false;
    post(CMD_CUE, current);
}

void audio_player_seek(uint32_t position_ms)
{
    if (track_count == 0)
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
    if (track_count == 0)
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
void audio_player_cue(size_t index) {}
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
