// Made by tools/gen_app_pictures.py from core/media/image_list.c: don't edit.

/// A picture built into the unit's firmware, by its name, with its
/// thumbnail in assets/pictures/.
class BuiltInPicture {
  final String name;
  final bool animated;
  const BuiltInPicture(this.name, this.animated);

  String get thumbnail => 'assets/pictures/$name.png';
}

const builtInPictures = [
  BuiltInPicture('katcorp', false),
  BuiltInPicture('hexcorp', false),
  BuiltInPicture('hal9000', false),
  BuiltInPicture('evileye', true),
];
