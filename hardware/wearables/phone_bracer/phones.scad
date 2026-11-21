// Phone sizes for the bracer's cradle. Each entry is
//
//   [name, length, width, thickness, corner radius, camera]
//
// in mm, for the bare phone, seen from the front, upright. camera is the
// camera bump on the back, as [from the top, from the left seen from the
// back, width, height, how far it stands out], so the cradle's plate can
// clear it. A bump that reaches the phone's sides, like the Pixel 8's bar,
// gives a width as wide as the phone.
//
// These are from the makers' published sizes, and the bumps are estimates.
// Measure your own phone before printing a cradle for it, and if a preset's
// off, say so, so it can be fixed here.

phones = [
    ["iPhone 15",          147.6, 71.6, 7.80, 11,  [4,  4, 32, 32, 2.0]],
    ["iPhone 15 Pro",      146.6, 70.6, 8.25, 11,  [4,  4, 38, 38, 3.5]],
    ["iPhone 15 Pro Max",  159.9, 76.7, 8.25, 12,  [4,  4, 41, 41, 3.5]],
    ["iPhone 16",          147.6, 71.6, 7.80, 11,  [4,  4, 20, 38, 2.5]],
    ["iPhone 16 Pro",      149.6, 71.5, 8.25, 11,  [4,  4, 39, 39, 3.5]],
    ["iPhone 16 Pro Max",  163.0, 77.6, 8.25, 12,  [4,  4, 42, 42, 3.5]],
    ["iPhone 17 Pro",      150.0, 71.9, 8.75, 11,  [3,  0, 71.9, 37, 3.5]],
    ["iPhone 17 Pro Max",  163.4, 78.0, 8.75, 12,  [3,  0, 78.0, 39, 3.5]],
    ["Pixel 8",            150.5, 70.8, 8.90, 10,  [16, 0, 70.8, 22, 3.0]],
    ["Pixel 9",            152.8, 72.0, 8.50, 10,  [13, 7, 58, 24, 3.0]],
    ["Pixel 9 Pro XL",     162.8, 76.6, 8.50, 10,  [14, 7, 62, 25, 3.0]],
    ["Pixel 10",           152.8, 72.0, 8.60, 10,  [13, 7, 58, 24, 3.0]],
    ["Galaxy S23",         146.3, 70.9, 7.60, 9,   [9,  9, 12, 40, 1.5]],
    // Measured in its case; the case covers the bump
    ["Galaxy S23 in OtterBox Defender", 153.5, 77.5, 13.5, 12, [8, 9, 17, 44, 1.0]],
    ["Galaxy S24",         147.0, 70.6, 7.60, 9,   [7,  9, 11, 36, 1.5]],
    ["Galaxy S24 Ultra",   162.3, 79.0, 8.60, 4,   [7,  7, 15, 46, 2.0]],
    ["Galaxy S25",         146.9, 70.5, 7.20, 9,   [7,  9, 11, 36, 1.5]],
    ["Galaxy S25 Ultra",   162.8, 77.6, 8.20, 6,   [7,  7, 15, 46, 2.0]],
];

function phone_preset(name) =
    let (found = [for (p = phones) if (p[0] == name) p])
    assert(len(found) == 1, str("No phone preset called \"", name, "\""))
    found[0];
