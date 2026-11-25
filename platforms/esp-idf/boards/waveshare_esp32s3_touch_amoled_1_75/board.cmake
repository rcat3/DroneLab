# Waveshare ESP32-S3-Touch-AMOLED-1.75
# https://docs.waveshare.com/ESP32-S3-Touch-AMOLED-1.75
set(IDF_TARGET esp32s3)
set(RCAT_IMAGE_SIZE 466)     # 466x466 round AMOLED
set(RCAT_LARGE_IMAGES OFF)   # big GIFs take a lot of flash at this size; put them on the SD card
set(RCAT_DEFAULT_ROTATION 2)   # 180 degrees: the housings turn the board so its USB-C port faces right
set(RCAT_HALF_TURNS_ONLY ON) # Rotation 0 or 180 only: the housings' collars turn the unit upright, and turning the picture in place leaves the RAM for the voice effects
set(RCAT_SPEAKER_OPTIONAL ON) # the speaker plugs in, and the low-profile housing has none
set(RCAT_VOICE_FX ON)        # voice effects: its echo canceller keeps the speaker from feeding back
