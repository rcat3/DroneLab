# libdronelab_fx for Android: the board's voice effects on the phone's
# microphone (voice_fx_app.c, core/audio/voice_fx_chain.c), and the studio
# chain (voice_studio_app.c, core/audio/studio/, RNNoise). Built by Gradle
# through ndk-build (android/app/build.gradle.kts, externalNativeBuild), so
# only the NDK's needed, not the SDK's CMake.
LOCAL_PATH := $(call my-dir)
CORE := $(LOCAL_PATH)/../../core
RNNOISE := $(LOCAL_PATH)/../../third_party/rnnoise

# RNNoise (third_party/rnnoise/DRONELAB.md), for the studio chain's denoise
include $(CLEAR_VARS)
LOCAL_MODULE := rnnoise_dl
LOCAL_SRC_FILES := $(addprefix ../../third_party/rnnoise/src/,denoise.c rnn.c pitch.c kiss_fft.c \
    celt_lpc.c nnet.c nnet_default.c parse_lpcnet_weights.c rnnoise_data.c rnnoise_tables.c)
LOCAL_C_INCLUDES := $(RNNOISE)/include $(RNNOISE)/src
LOCAL_CFLAGS := -O2 -fvisibility=hidden -Wno-cpp
include $(BUILD_STATIC_LIBRARY)

include $(CLEAR_VARS)
LOCAL_MODULE := dronelab_fx
LOCAL_SRC_FILES := voice_fx_app.c ../../core/audio/voice_fx_chain.c ../../core/audio/fft.c \
    voice_studio_app.c $(addprefix ../../core/audio/studio/,studio.c sfft.c dynamics.c filters.c \
    spectral.c pitch.c echo.c reverb.c denoise.c)
LOCAL_C_INCLUDES := $(CORE) $(RNNOISE)/include
LOCAL_CFLAGS := -O2 -fvisibility=hidden -Wall
LOCAL_STATIC_LIBRARIES := rnnoise_dl
LOCAL_LDLIBS := -lm
include $(BUILD_SHARED_LIBRARY)
