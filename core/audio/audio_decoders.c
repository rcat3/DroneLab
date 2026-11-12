/*
 * Builds the dr_libs decoders used by the audio player. They need a
 * filesystem to read from, so they're left out on platforms without one.
 */
#if RCAT_HAVE_FILESYSTEM

// dr_mp3 keeps at least 16 KB of the file ahead of the decoder, and by default
// tops it back up to 64 KB, reading 48 KB at once. From an SD card that takes
// longer than the speaker's buffer lasts, so there was a gap every few
// seconds. A little over 16 KB means it reads about 4 KB at a time instead.
#define DRMP3_DATA_CHUNK_SIZE (16384 + 4096)

#define DR_FLAC_IMPLEMENTATION
#define DR_MP3_IMPLEMENTATION
#define DR_WAV_IMPLEMENTATION
#include "audio/audio_decoders.h"

#endif
