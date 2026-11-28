/* DroneLab: not part of the RNNoise 0.2 release download, though vec.h and
 * vec_neon.h include it (it's Opus's celt/os_support.h in RNNoise's git
 * tree). Only what RNNoise uses from it, on top of its own common.h. See
 * DRONELAB.md. */
#ifndef OS_SUPPORT_H
#define OS_SUPPORT_H

#include "common.h"

#ifndef OPUS_INLINE
#define OPUS_INLINE inline
#endif
#define OPUS_CLEAR(dst, n) RNN_CLEAR(dst, n)
#define OPUS_COPY(dst, src, n) RNN_COPY(dst, src, n)
#define OPUS_MOVE(dst, src, n) RNN_MOVE(dst, src, n)

#endif
