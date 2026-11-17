// The 1.75" speaker housing's parts one at a time, for the design README's
// table of parts. render.sh sets show to each part's name in turn. They're
// the way round they sit in the housing, except the washer and the plungers,
// which are shown as they come off the printer.
include <../../hardware/boards/waveshare_esp32s3_touch_amoled_1_75/msa_speaker_housing.scad>
show = "body";
if (show == "body") color("#8c8c8c") body();
if (show == "chin") color("#8c8c8c") chin();
if (show == "back") color("#8c8c8c") back();
if (show == "collar") color("#8c8c8c") collar();
if (show == "washer") color("#9a9a9a") washer_print();
if (show == "gasket") color("#b05a2a") gasket();
if (show == "plungers") color("#8c8c8c") for (i = [0, 1]) translate([i * 8, 0, 0]) plunger();
if (show == "usb_plug") color("#8c8c8c") usb_plug();
