# Voice Lab

*Boards with a microphone and WiFi: the ESP32-S3 boards*

The Voice Lab streams the board's microphone over WiFi to `tools/voice_monitor.py` on a computer, which plays it, records it and runs it through voice effects.  It's for trying out effects with the real microphone in the mask before building them into the firmware (see [Voice Effects](voice-effects.md)).

1. Put a file called `wifi.txt` on the SD card with your WiFi network's name and password (2.4 GHz networks only):
   ```
   ssid=My Network
   password=my password
   ```
2. Install the monitor's packages on the computer: `pip install numpy sounddevice` (on Linux, sounddevice also needs PortAudio: `sudo apt install libportaudio2`).
3. On the board, go to the last page of the Voice feature and switch the Voice Lab on.  It shows the board's address once it's connected.
4. On the computer, run `python3 tools/voice_monitor.py`.  It finds the board on the network, and the board shows *Streaming to* the computer's address.  If it isn't found, give the board's address: `python3 tools/voice_monitor.py --board 192.168.1.23`.

Some things to try:

- `--effect robot` (or `deep`, `dalek`, `drone`, `android`) plays the microphone through an effect.  Effects can be chained, like `--effect gate:-45,pitch:0.8,ring:40`.  Run with `--help` for the list.
- `--record take1.wav` saves the microphone as it is.  Then `--input take1.wav --effect robot` tries effects on the recording, without the board.
- `--listen effect` plays the board's own voice effect instead of the microphone, on a board with [voice effects](voice-effects.md).
- `--meter` prints the microphone level every second.  Play something on the speaker (the [Sound](sound.md) feature) to measure how much the microphone picks up.

- `--gain 12` turns everything received up by 12 dB.  The microphone and the board's effect come in quiet, peaking around −22 dBFS, so 12 to 15 dB suits most voices.  Recordings say how loud they peaked when they're closed, and how many samples clipped if it was too much.
- `--device` plays to a different sound device, by number or part of its name.  `--list-devices` lists them.

No recording is ever written over: if the file's there already, the new one gets `-2`, `-3` and so on before the `.wav`.


For recording the voice effect for videos, the DroneLab app's *Record* tab is the easier way: see [Recording in the app](#recording-in-the-app).
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

The Voice Lab is off whenever the board starts, and WiFi is off while it's off.  The Voice Lab and the [WiFi Hotspot Remote](phone-remote.md) both use WiFi, so they can't run at once: switching one on stops the other.

## Recording in the app

The DroneLab app's *Record* tab records the board's voice, after the effect, straight to the phone, over the same Bluetooth link as the [comm channel](comm.md), with no computer or WiFi.  Pick the *Speaker voice* (the effect the board plays) or the *Comm voice* (the [Comm Voice](comm.md#comm-voice), if it's different), and, if you like, a *Sync beep*: the board beeps as it starts, and the same beep's in the recording, for lining it up with video.  The microphone's left out of the recording while it beeps, and a moment after, so the beep it picks up from the speaker doesn't follow as a second one.

Each recording is a 48 kHz mono WAV, the voice sent at 48 kb/s (the effect itself runs at 16 kHz, so that's as much as there is to hear).  The list under the button plays, shares (to Google Drive, email and the rest, from Android's share sheet) and deletes them.  Comms stop while it records, the server and direct comms, and start again after; the board shows REC.  The voice is evened out by the comm channel's automatic gain, as on the channel.

## Recording over Bluetooth

`tools/ble_record.py` does what the app's Record tab does on a computer, over Bluetooth, so the computer stays on its own network, with no hotspot to join:

```
python3 tools/ble_record.py --beep --take intro      # to intro.wav, with a sync beep
python3 tools/ble_record.py --play                   # and hear it as it records
python3 tools/ble_record.py --device "CABLE Input" --no-record   # a video call's microphone
```

Enter stops it.  It records the speaker's voice effect, or the comm voice with `--comm-voice`, to a 48 kHz mono WAV named for when it starts, never written over.  Played to a virtual audio cable with `--device` (see `--list-devices`), the board's voice can be a video call's microphone, as above.

The board talks to one phone or computer at a time, so disconnect the app first: while it's connected, the board isn't even found.  The computer has to be paired with the board once, as a phone does, with the code the board shows: without it, the board connects but won't take the request to record.  On Linux:

```
python3 tools/ble_pair.py
```

It asks you to open pairing on the board (Settings, *Paired Phones*, *Pair a phone*) and disconnect the app, finds the board, asks for the code the board shows, and leaves it free afterwards.  On Windows and macOS, pair it in the system's Bluetooth settings instead.  After that, `ble_record.py` finds the board by itself, even if this computer's left connected to it from before.  It needs `pip install bleak`, libopus (the `libopus0` package on Debian and Ubuntu, `opus` from Homebrew on macOS), and for `--play` or `--device`, `numpy` and `sounddevice`.

