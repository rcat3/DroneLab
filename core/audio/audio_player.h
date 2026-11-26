#ifndef RCAT_AUDIO_PLAYER_H
#define RCAT_AUDIO_PLAYER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* What happens at the end of a track. */
typedef enum
{
    AUDIO_REPEAT_ALL,       // play the next track, and start again after the last one
    AUDIO_REPEAT_ONE,       // play the same track again
    AUDIO_REPEAT_OFF,       // stop
    AUDIO_REPEAT_COUNT
} audio_repeat_t;

/* Find the sound files in a folder on storage (its "sounds" subfolder) and
 * start the speaker. Returns false if the board has no speaker. Finding no
 * files isn't an error: the player is still there, with nothing to play. */
bool audio_player_init(const char *storage_path);

/* True once audio_player_init() has succeeded. */
bool audio_player_available(void);

/* The playlist: every sound file found, sorted by name, then the sounds
 * others have sent (below). Names are shown without the file extension. */
size_t audio_player_track_count(void);
const char *audio_player_track_name(size_t index);

/* A sound file's been saved to the card's sounds folder (app/storage_save.h),
 * or is to be deleted from it: the track's added after the card's others, or
 * stopped, taken away and its file deleted, while whatever plays carries on.
 * Done by the speaker's task; false if it's not taken (no speaker, or too
 * many waiting). From the UI loop. */
bool audio_player_file_added(const char *file_name);
bool audio_player_remove_file(const char *file_name);

/* How many more sound files from the card the list has room for. */
size_t audio_player_file_room(void);

/* Play a track from the start. */
void audio_player_play(size_t index);

/* Play a track once, over whatever's playing or paused, which comes back
 * afterwards where it was: for a short sound when something happens. The
 * player shows what it plays over meanwhile. Anything else asked of the
 * player ends it. */
void audio_player_chime(size_t index);

/* Stop a chime part way, back to what was there; and whether one's playing. */
void audio_player_chime_stop(void);
bool audio_player_chiming(void);

/* Sounds others have sent (app/sounds.h): each played once as it comes, as
 * a chime, so nothing shows, and kept as a track after the SD card's, the
 * last AUDIO_SENT_KEPT of them, the oldest going first, in memory only. One
 * plays for AUDIO_SENT_MAX_MS at most, however long it is. */
#define AUDIO_SENT_KEPT     2
#define AUDIO_SENT_MAX_MS   10000
#define AUDIO_SENT_NAME_LEN 48
#define AUDIO_SENT_OPUS     0       // Opus packets, each after its length (1 byte), mono
#define AUDIO_SENT_FILE     1       // a WAV, MP3 or FLAC file, as it is

/* Play a sound sent, and keep it, named name: data's taken (malloc'd), and
 * freed when it goes. One already kept, by its SHA-256, is played again.
 * Returns false if there's no speaker, and data's freed. From the UI loop. */
bool audio_player_add_sent(uint8_t *data, size_t len, uint8_t kind, const uint8_t hash[32], const char *name);

/* Whether a track's one sent, how many are, and deleting one. From the UI
 * loop. */
bool audio_player_is_sent(size_t index);
size_t audio_player_sent_count(void);
void audio_player_delete_sent(size_t index);

/* Goes up whenever the tracks change (a sound's sent, or deleted), for
 * lists of them to be asked for again. From any task. */
uint32_t audio_player_tracks_changes(void);

/* For the speaker's task, each time it wants sound: takes in the sounds
 * sent and deleted since, and says whether one sent is playing, which plays
 * in place of the voice effect while it does. */
bool audio_player_sent_playing(void);

/* Choose a track without playing it. Resuming plays it from the start. */
void audio_player_cue(size_t index);

/* Move to a time in the track that's playing or paused, in milliseconds,
 * carrying on playing or staying paused. In an MP3, it's found in
 * proportion to the file's length, which is exact for a constant bitrate and
 * close for a variable one. */
void audio_player_seek(uint32_t position_ms);

/* Pause and carry on from the same place. */
void audio_player_pause(void);
void audio_player_resume(void);

bool audio_player_is_playing(void);

/* The track that's playing or paused, or was played last. */
size_t audio_player_current(void);

/* How far into the track that's playing or paused it is, and how long the
 * track is, in milliseconds. The length is 0 while it isn't known: before
 * the track starts, or for a file that doesn't say. For an MP3 that doesn't
 * say, it's worked out from the file's size and how fast it's being read, so
 * it may move a little at first. */
void audio_player_progress(uint32_t *position_ms, uint32_t *length_ms);

void audio_player_set_volume(uint8_t percent);
void audio_player_set_repeat(audio_repeat_t repeat);

/* For the speaker: decode up to max_frames frames of stereo (see
 * rcat_hal_audio_fill_cb_t). Called on the speaker's task. */
size_t audio_player_fill(int16_t *frames, size_t max_frames, uint32_t *sample_rate);

#endif
