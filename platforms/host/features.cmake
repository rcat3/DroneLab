# Which features to build for the virtual unit: ON to build one in, OFF to
# leave it out. See core/features.cmake.

set(RCAT_FEATURE_IMAGES ON)     # images and animations
set(RCAT_FEATURE_VISUALIZER ON) # pictures of the voice and the speaker
set(RCAT_FEATURE_VOICE  ON)     # the voice ring, voice effects and the voice lab
set(RCAT_FEATURE_SOUND  ON)     # sound file player
set(RCAT_FEATURE_COMM   ON)     # the comm channel's status screen, through the app
set(RCAT_FEATURE_LEVEL  OFF)    # no accelerometer
set(RCAT_FEATURE_TOYS ON)       # with virtual toys, for now (see toys.h)
set(RCAT_FEATURE_TERMINAL ON)   # green screen text, typed in on the remote in the app
