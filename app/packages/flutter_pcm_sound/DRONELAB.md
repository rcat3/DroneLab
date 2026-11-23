flutter_pcm_sound 3.3.3 (public domain, see LICENSE), copied here for one
change: `setup(androidVoiceCall: true)` plays as a call's voice
(USAGE_VOICE_COMMUNICATION), so it goes to a Bluetooth headset in call mode
when the app talks from the headset's mic. Also fixed: after release()
or a second setup(), start() didn't feed again (`_needsStart` stayed false),
so playback stayed silent until the app restarted. The example and site folders are
left out.
And underruns(): AudioTrack.getUnderrunCount, for the app's developer command /heard.
