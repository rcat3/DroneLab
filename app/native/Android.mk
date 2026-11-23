# libdronelab_fx for Android: the board's voice effects on the phone's
# microphone (voice_fx_app.c, core/audio/voice_fx_chain.c). Built by Gradle
# through ndk-build (android/app/build.gradle.kts, externalNativeBuild), so
# only the NDK's needed, not the SDK's CMake.
LOCAL_PATH := $(call my-dir)
CORE := $(LOCAL_PATH)/../../core

include $(CLEAR_VARS)
LOCAL_MODULE := dronelab_fx
LOCAL_SRC_FILES := voice_fx_app.c ../../core/audio/voice_fx_chain.c ../../core/audio/fft.c
LOCAL_C_INCLUDES := $(CORE)
LOCAL_CFLAGS := -O2 -fvisibility=hidden -Wall
LOCAL_LDLIBS := -lm
include $(BUILD_SHARED_LIBRARY)
