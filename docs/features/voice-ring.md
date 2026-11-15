# Voice Ring

*Boards with a microphone: the ESP32-S3 boards*

The voice's settings are pages of the [Visualizer](visualizer.md), after its own two, swiping left: the Voice Ring's settings, the [Voice Effect](voice-effects.md) and its volume (on the ESP32-S3-Touch-AMOLED-1.75), and the [Voice Lab](voice-lab.md).  They used to be a Voice feature of their own, whose first page was the Voice Ring's colors: swiping up or down through the features would catch the color roller and change the color.  The Visualizer's first page is the picture itself, which a swipe can't change.  (On boards without the Visualizer, they're still a Voice feature.)

## Voice Ring

A ring around the edge of the screen that glows with your voice while the [Images](images.md) feature is on screen.  Its page switches it on and off and picks its color, from nine, and shows the ring while you choose.  The [Phone Remote](phone-remote.md) can do both too.

## How it follows your voice

The Voice Ring adjusts to the surroundings on its own.  A quiet room stays dark, normal talking uses most of the range, and it scales back for loud talking or a noisy room.  It takes a few seconds to adjust.
