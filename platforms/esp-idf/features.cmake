# Which features to build for the ESP32 boards: ON to build one in, OFF to
# leave it out. See core/features.cmake.

set(RCAT_FEATURE_IMAGES ON)     # images and animations
set(RCAT_FEATURE_VISUALIZER ON) # pictures of the voice and the speaker: KITT, a 3D spectrum and more
set(RCAT_FEATURE_VOICE  ON)     # the voice ring, voice effects and the voice lab
set(RCAT_FEATURE_SOUND  ON)     # sound file player
set(RCAT_FEATURE_COMM   ON)     # the comm channel's status screen, through the phone app (boards with it)
set(RCAT_FEATURE_LEVEL  ON)     # spirit level in Settings, for lining the display up on the mask
set(RCAT_FEATURE_TOYS ON)       # HiveMind Control's toys, over Bluetooth (Lovense for now)
set(RCAT_FEATURE_TERMINAL ON)   # green screen text, typed in on the phone remote

