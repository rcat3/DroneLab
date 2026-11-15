# Voice Lab

*Boards with a microphone and WiFi: the ESP32-S3 boards*

The Voice Lab streams the board's microphone over WiFi to `tools/voice_monitor.py` on a computer, which plays it, records it and runs it through voice effects.  It's for trying out effects with the real microphone in the mask before building them into the firmware (see [Voice Effects](voice-effects.md)).

1. Put a file called `wifi.txt` on the SD card with your WiFi network's name and password (2.4 GHz networks only):
   ```
   ssid=My Network
   password=my password
   ```
2. Install the monitor's packages on the computer: `pip install numpy sounddevice` (on Linux, sounddevice also needs PortAudio: `sudo apt install libportaudio2`).
3. On the board, go to the last page of the Visualizer feature and switch the Voice Lab on.  It shows the board's address once it's connected.
4. On the computer, run `python3 tools/voice_monitor.py`.  It finds the board on the network, and the board shows *Streaming to* the computer's address.  If it isn't found, give the board's address: `python3 tools/voice_monitor.py --board 192.168.1.23`.

Some things to try:

- `--effect robot` (or `deep`, `dalek`, `drone`, `android`) plays the microphone through an effect.  Effects can be chained, like `--effect gate:-45,pitch:0.8,ring:40`.  Run with `--help` for the list.
- `--record take1.wav` saves the microphone as it is.  Then `--input take1.wav --effect robot` tries effects on the recording, without the board.
- `--listen effect` plays the board's own voice effect instead of the microphone, on a board with [voice effects](voice-effects.md).
- `--meter` prints the microphone level every second.  Play something on the speaker (the [Sound](sound.md) feature) to measure how much the microphone picks up.

- `--gain 12` turns everything received up by 12 dB.  The microphone and the board's effect come in quiet, peaking around −22 dBFS, so 12 to 15 dB suits most voices.  Recordings say how loud they peaked when they're closed, and how many samples clipped if it was too much.
- `--device` plays to a different sound device, by number or part of its name.  `--list-devices` lists them.

No recording is ever written over: if the file's there already, the new one gets `-2`, `-3` and so on before the `.wav`.

## Recording for video

To use the voice effect as the sound of a video, instead of a microphone on the outside of the mask picking up your real voice:

```
python3 tools/voice_monitor.py --take scene1 --beep --gain 12
```

That records two files: the board's voice effect to `scene1-effect.wav`, and the microphone as it is to `scene1-mic.wav`, in case you want to try a different effect on it later (with `--input`).

With `--beep`, the board beeps from its speaker about a second after recording starts and again when you press Ctrl+C to stop, and the same beep goes into both files at the moment it sounds.  Pressing Enter beeps again whenever you like.  The camera hears the beeps, so in the video editor, line the beeps in the files up with the beeps in the camera's sound, and the voice lines up with your mouth.  The beep at the end is for long takes: if the board's clock and the camera's drift apart, stretch the file until both beeps match.  The beep is added to the files about 25 ms after the board makes it, which is how long the speaker takes to play it, worked out from its buffers and not measured, so it should land within a frame of the camera's.  The voice effect itself comes out a little behind your voice, by up to a few tens of milliseconds depending on the effect, so nudge it by a frame if the lips look off.

The files are WAV, at 16 kHz for the effect and 32 kHz for the microphone, which keeps them exact for lining up.  Video editors take WAV directly, and a minute is about 2 MB, so there's no need for MP3, which adds a little silence at the start and loses quality each time it's re-encoded.

The Voice Lab needs a WiFi network from `wifi.txt`.  Away from home, a phone's hotspot does, with the computer on it too.

## As a microphone in video calls

Zoom, Google Meet, Teams and the like can use the voice effect as their microphone, through a virtual audio cable: a pretend sound device that the monitor plays into, and that the call app hears as a microphone.

- **Windows**: install [VB-CABLE](https://vb-audio.com/Cable/).  Run `python3 tools/voice_monitor.py --listen effect --gain 12 --device "CABLE Input"`, and choose *CABLE Output* as the microphone in the call.
- **macOS**: install [BlackHole](https://github.com/ExistentialAudio/BlackHole) (2ch).  Run `python3 tools/voice_monitor.py --listen effect --gain 12 --device BlackHole`, and choose *BlackHole 2ch* as the microphone.
- **Linux** (PipeWire or PulseAudio): make a sink to play into, and a microphone that hears it, until the next login:
  ```
  pactl load-module module-null-sink sink_name=dronelab sink_properties=device.description=DroneLab
  pactl load-module module-remap-source master=dronelab.monitor source_name=dronelab_mic source_properties=device.description=DroneLab-Mic
  PULSE_SINK=dronelab python3 tools/voice_monitor.py --listen effect --gain 12 --device pulse
  ```
  and choose *DroneLab-Mic* as the microphone.

Turn off the call app's noise suppression if it's cutting into the effect, as some of the effects sound like noise to it.

WiFi adds a delay of around a tenth of a second, which is fine for judging an effect but odd if you listen to yourself live.  It's easier to have someone else listen, or to record and play back.

The Voice Lab is off whenever the board starts, and WiFi is off while it's off.  The Voice Lab and the [Phone Remote](phone-remote.md) both use WiFi, so they can't run at once: switching one on stops the other.
