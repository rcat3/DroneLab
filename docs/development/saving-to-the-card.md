# Saving to the SD card

How the app puts a picture or a sound on the unit's SD card (comm message `0x1D`, from COMM_VERSION 24), and how the unit takes it into its lists without a restart.  The user's side is in [Remote](../app/remote.md#saving-pictures-and-sounds-to-the-units-sd-card).

The code: [`core/app/storage_save.c`](../../core/app/storage_save.c) on the unit, [`app/lib/comm/unit_storage.dart`](../../app/lib/comm/unit_storage.dart) (the transfer), [`card_media.dart`](../../app/lib/comm/card_media.dart) (making a file ready) and [`card_saving.dart`](../../app/lib/ui/card_saving.dart) (the screens) in the app.  Tests: [`unit_storage_test.dart`](../../app/test/unit_storage_test.dart).

## The message

Modelled on the picture and sound messages (`0x1A`, `0x1B`), [`comm.h`](../../core/app/comm.h) has the layout.  The differences:

- **Each piece carries where it goes** (4 bytes), as the firmware update's do, so a piece that doesn't fit where the file's got to is left out, not an error.  The ack says how much has come, and the app sends again from there.  That is the whole of resuming: it covers a piece lost on the link, and an ack lost on the way (the app asks again after a few seconds, by sending the next piece).  It doesn't survive a disconnect: the unit deletes what it had when the phone goes.
- **The start names the file** (ASCII, at most 64 bytes, with its extension) and its kind (picture or sound), and is always acked, with a result code (`save_result_t`) in the ack's last byte.  A name that's taken is refused (`SAVE_EXISTS`); the app deletes the old file first if the wearer says to replace it.
- **The unit streams to `<name>.part`**, hashing as it goes, and at the end checks the SHA-256 and renames.  `*.part` files are deleted at startup and when a transfer ends badly.
- A picture is **loaded as it's saved** (`media_add_file`): if the unit can't show it, the file is deleted and the end's ack says `SAVE_BAD_FILE`.  Decoding takes up to a second or two, so the app waits longer for the end's ack than for the others.

Where the files go: sounds are always in `sounds/`.  Pictures go in `images/`, as the media library reads them, but if there's no `images/` folder and the card's top level has pictures (the library's fallback), they go there, so saving one doesn't hide the others at the next start.

## Taking a file into the lists

- **Pictures**: `media_add_file()` loads the file as the start-up scan does and puts it among the storage pictures by name; `feature_images_add_stored()` puts a page at the same place.  Deleting is the reverse.  A page's name and its startup choice each have a copy of the name, because the media list moves as it changes.  The Startup choices list isn't changed while it runs (Settings' roller and the remote's list are built from it by index): a new picture can be chosen there after a restart, and a deleted one's choice just has nowhere to go.
- **Sounds**: the speaker's task owns the track list, so `audio_player_file_added()` and `audio_player_remove_file()` put the change in a small queue, and the task takes it in with the sent sounds: a new track goes after the card's others (not sorted in, so what plays carries on, and the indexes of those before it don't move), and the sent sounds' indexes move up by one.  Removing a track that plays stops it first.  The speaker task deletes the file, so it isn't open while it goes.

## The app

[`UnitStorage`](../../app/lib/comm/unit_storage.dart) is owned by the `CommController`, not the Remote page, so a file carries on when the wearer leaves the page.  It does one file at a time, a window of 8 pieces then an ack, and:

- waits while voice is on (`voiceBusy`: the board is sending or hearing voice, or there's a call), and pauses the Remote's polling to every third tick meanwhile;
- gives up after four unanswered asks, and clears what was queued behind a failure, which would likely fail the same way;
- is cancelled from the progress row, and sends an abort (flag bit 3) whenever a file fails or is cancelled, so the unit deletes its `.part` and lets the player carry on.  The unit also drops one that's been quiet for 20 seconds.

`GET /api/storage` lists the pictures and sounds (`"pictures"`, `"sounds"`), the card's room and whether one is coming; `POST /api/storage?kind=<0 or 1>&del=<name>` deletes one and answers the same, with `"result"`.

## Making a file ready

A picture is shrunk to the screen's size (466 px), so the unit decodes less, and saved as a JPEG; a GIF is saved as it is (up to 640 px across and 2 MB, as the sent GIFs are), and a PNG with transparency stays a PNG.  A sound is saved as it is, except a 16-bit WAV that's stereo or over 3 MB: mixed to mono, then its rate halved until it fits.  MP3 and FLAC aren't touched.  Both are run off the UI's isolate (`compute`).
