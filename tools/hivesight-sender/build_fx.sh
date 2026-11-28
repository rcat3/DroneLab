#!/bin/sh
# Builds libdronelab_fx (the voice effects library the sender uses, the same
# one the desktop app bundles) and the tests' libstudio_test into build/, for
# running the sender by hand or the tests. The desktop app builds its own copy
# (app/linux/CMakeLists.txt) and passes it to the sender with --fx-lib.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT="$HERE/build"
CC=${CC:-cc}
mkdir -p "$OUT"

R="$ROOT/third_party/rnnoise"
S="$ROOT/core/audio/studio"
RNN_SRC="denoise rnn pitch kiss_fft celt_lpc nnet nnet_default parse_lpcnet_weights rnnoise_data rnnoise_tables"
STUDIO_SRC="studio sfft dynamics filters spectral pitch echo reverb denoise character"

# RNNoise once into objects (its weights take a while to compile)
for f in $RNN_SRC; do
    o="$OUT/rnn_$f.o"
    if [ ! -f "$o" ] || [ "$R/src/$f.c" -nt "$o" ]; then
        $CC -O2 -fPIC -fvisibility=hidden -Wno-cpp -I"$R/include" -I"$R/src" -c "$R/src/$f.c" -o "$o"
    fi
done
RNN_OBJ=$(for f in $RNN_SRC; do printf '%s ' "$OUT/rnn_$f.o"; done)
STUDIO=$(for f in $STUDIO_SRC; do printf '%s ' "$S/$f.c"; done)

CFLAGS="-O2 -fPIC -fvisibility=hidden -Wall -Wextra -Wno-unused-parameter -I$ROOT/core -I$R/include"
# shellcheck disable=SC2086
$CC $CFLAGS -shared -o "$OUT/libdronelab_fx.so" "$ROOT/app/native/voice_studio_app.c" \
    "$ROOT/app/native/voice_fx_app.c" "$ROOT/core/audio/voice_fx_chain.c" "$ROOT/core/audio/fft.c" \
    $STUDIO $RNN_OBJ -lm
# shellcheck disable=SC2086
$CC $CFLAGS -shared -o "$OUT/libstudio_test.so" "$HERE/tests/studio_test.c" $STUDIO $RNN_OBJ -lm
echo "built $OUT/libdronelab_fx.so"
