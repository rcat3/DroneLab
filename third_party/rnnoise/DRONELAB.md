# RNNoise in DroneLab

RNNoise 0.2 by Jean-Marc Valin, Xiph.Org and others (BSD licence, see `COPYING`),
copied from the release download:

- https://github.com/xiph/rnnoise/releases/download/v0.2/rnnoise-0.2.tar.gz
- sha256 `90fce4b00b9ff24c08dbfe31b82ffd43bae383d85c5535676d28b0a2b11c0d37`

Copied rather than added as a submodule because the model's weights
(`src/rnnoise_data.c`) only come with the release download, not in the git
repository. Only `include/`, `src/` and the licence files are kept; nothing in
them is changed, but one file is added: `src/os_support.h`, which `vec.h` and
`vec_neon.h` include and the release leaves out (it's Opus's, in RNNoise's git
tree). Ours defines only the few macros RNNoise uses, from its own `common.h`.
Without it only the x86 (SSE/AVX) path compiles; ARM and plain C need it.

It removes noise from the Guide's voice in HiveSight (`core/audio/studio/`, the
`denoise` setting), inside `libdronelab_fx`. Built as plain C without
`config.h` or the x86 run-time CPU detection: the files used are `denoise.c rnn.c
pitch.c kiss_fft.c celt_lpc.c nnet.c nnet_default.c parse_lpcnet_weights.c
rnnoise_data.c rnnoise_tables.c`, with `-Wno-cpp` for its "only SSE2" warning on
x86-64. It adds about 1.4 MB to the library, nearly all of it the weights.

To update: download the new release, check its sha256, replace `include/` and
`src/`, and rerun `tools/hivesight-sender/tests/run_tests.py`.
