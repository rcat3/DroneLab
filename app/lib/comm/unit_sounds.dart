/// Sounds the unit plays for what happens, from the sound files on its SD
/// card: one picked for each event, or none. The app tells the unit to play
/// it (POST /api/sound?chime=), once, over whatever its player's doing,
/// which carries on after. Needs a unit with a speaker.
library;

enum UnitSoundEvent {
  call('Incoming call', 'Someone calling you'),
  text('Text message', 'A text or photo comes in'),
  lovense('Toy command', 'Someone sends your toys a command, and it is taken'),
  terminal('Display message', 'Someone puts words on your display, and they are taken'),
  nearby('Unit nearby', 'A unit is heard over direct mode, not heard in the last 10 minutes');

  final String title;
  final String help;
  const UnitSoundEvent(this.title, this.help);
}

/// The same event again this soon plays nothing, so a run of them (a toy's
/// slider dragged, a burst of texts) is one sound.
const unitSoundGapMs = 3000;

/// A unit heard again after this long counts as new.
const nearbyAgainMs = 10 * 60 * 1000;

/// No unit counts as new for this long after the board connects or direct
/// comes on, when everyone about is heard at once.
const nearbySettleMs = 20000;
