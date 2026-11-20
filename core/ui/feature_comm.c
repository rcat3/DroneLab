/*
 * Comm feature (boards with the comm channel, see app/comm.h): how the
 * channel's doing, at a glance, and its settings.
 *
 * The first page is the status screen, a green screen like the Terminal's:
 * "HiveMind" and an antenna at the top, which is struck through in red with no
 * uplink (the phone's app), yellow without its waves while there's no server,
 * and green with its waves once everything's connected. In the middle, an
 * avatar in a frame: whoever's talking (RX), in full color, or the wearer,
 * full color and bright while the board sends (TX), with a ring round the
 * edge, and dim and green while it's quiet. Holding it talks, and while it
 * talks the page can't be swiped away.
 *
 * Everything that changes is only redrawn when it does, and the avatar's
 * look (its brightness, color, scanlines) is baked into its pixels once, as
 * it changes, so the screen keeps up with the talking.
 *
 * Then Comm Setup: push to talk or voice, whether the speaker goes quiet
 * while it sends, and whether to come to the status screen while it sends
 * or hears someone, going back to where it was afterwards. Then Direct:
 * direct comms, board to board (app/direct.h), with the boards it hears. And
 * the talk button. Switching the phone app's link on, and pairing phones, are in
 * Settings, as the remote uses them too.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "app/comm.h"
#include "app/direct.h"
#include "app/settings.h"
#include "app/talk_button.h"
#include "audio/voice_fx.h"
#include "ui/ui.h"
#include "ui/ui_internal.h"

LV_FONT_DECLARE(terminal_font_2)
LV_FONT_DECLARE(terminal_font_3)

#define UPDATE_MS           30
#define HOLD_TO_TALK_MS     150     // a finger on the avatar this long talks; a swipe across it doesn't
#define RETURN_AFTER_MS     2000    // back to where it was, this long after the talking stops

#define AVATAR_DESIGN_PX    116     // shown this big, in the 240 design
#define AVATAR_SCALE        2       // each of the avatar's pixels is 2x2 on screen
#define SCANLINE            150     // every other row this bright, of 256, for a CRT's look

// A green screen's phosphor, brighter as more is going on, and white-hot
// for TX. Yellow and red only for the antenna's warnings.
#define PHOSPHOR_HEX        0x3CFF6E
#define COLOR_HOT           lv_color_hex(0xD8FFE0)
#define COLOR_PHOSPHOR      lv_color_hex(PHOSPHOR_HEX)
#define COLOR_MID           lv_color_hex(0x1E9C45)
#define COLOR_DIM           lv_color_hex(0x0C4A20)
#define COLOR_WARN          lv_color_hex(0xFFD21F)
#define COLOR_ALERT         lv_color_hex(0xFF3B30)
#define COLOR_MUTED         lv_palette_main(LV_PALETTE_GREY)

static bool build(ui_feature_t *feature);
static void on_navigate(void);

const ui_feature_def_t feature_comm = {
    .name = "HiveMind",
    .build = build,
    .on_navigate = on_navigate,
};

/* Set a label's text only if it's changed, so it isn't redrawn every time. */
static void set_label(lv_obj_t *label, const char *text)
{
    if (strcmp(lv_label_get_text(label), text) != 0)
    {
        lv_label_set_text(label, text);
    }
}

static bool touching(void)
{
    for (lv_indev_t *i = lv_indev_get_next(NULL); i != NULL; i = lv_indev_get_next(i))
    {
        if (lv_indev_get_type(i) == LV_INDEV_TYPE_POINTER && lv_indev_get_state(i) == LV_INDEV_STATE_PRESSED)
        {
            return true;
        }
    }
    return false;
}

/* ----- Pixel art ----- */

// The antenna: '#' its mast, 'w' its waves
static const char *const antenna_art[] = {
    ".w.........w.",
    "w..w.....w..w",
    "w.w...#...w.w",
    "w.w..###..w.w",
    "w..w..#..w..w",
    ".w....#....w.",
    "......#......",
    "......#......",
    ".....###.....",
    "....#.#.#....",
    "...#..#..#...",
    "..#...#...#..",
};
#define ANTENNA_W   13
#define ANTENNA_H   12

// Whoever hasn't got an avatar: a head in a visor. '#' light, '+' dark.
static const char *const nobody_art[] = {
    "................",
    "......####......",
    "....########....",
    "...##########...",
    "..############..",
    "..############..",
    "..#++++++++++#..",
    "..#+########+#..",
    "..#++++++++++#..",
    "..############..",
    "...##########...",
    "....###++###....",
    ".....######.....",
    "................",
    "..############..",
    ".##############.",
};
#define NOBODY_PX   16

typedef enum
{
    ANTENNA_UP,         // everything's connected
    ANTENNA_NO_SERVER,  // the app's there, the server isn't
    ANTENNA_DOWN,       // no uplink
    ANTENNA_COUNT,
} antenna_t;

static lv_image_dsc_t antenna_icons[ANTENNA_COUNT];

// Where talking goes, by the name while it's sent: the server (a cloud), or
// direct comms (a handheld radio)
static const char *const cloud_art[] = {
    ".....###.....",
    "....#####....",
    "..#########..",
    ".###########.",
    "#############",
    "#############",
    ".###########.",
};
static const char *const radio_art[] = {
    "#........",
    "#........",
    "#........",
    "#########",
    "#.......#",
    "#.#####.#",
    "#.#####.#",
    "#.......#",
    "#.#.#.#.#",
    "#.......#",
    "#.#.#.#.#",
    "#.......#",
    "#########",
};
static lv_image_dsc_t transport_icons[COMM_TALK_COUNT];

/* An A8 picture of '#'s in art, scale screen pixels to each of its own. */
static void make_icon(lv_image_dsc_t *dsc, const char *const *art, int w, int h, int scale)
{
    int pw = w * scale, ph = h * scale;
    uint8_t *px = lv_malloc_zeroed((size_t)pw * ph);
    for (int y = 0; y < ph; y++)
    {
        for (int x = 0; x < pw; x++)
        {
            px[y * pw + x] = art[y / scale][x / scale] == '#' ? 0xFF : 0;
        }
    }
    *dsc = (lv_image_dsc_t){
        .header = { .magic = LV_IMAGE_HEADER_MAGIC, .cf = LV_COLOR_FORMAT_A8, .w = pw, .h = ph, .stride = pw },
        .data_size = (uint32_t)(pw * ph),
        .data = px,
    };
}

/* An A8 picture of the antenna, scale screen pixels to each of its own,
 * drawn in whatever color its image is given. */
static void make_antenna(lv_image_dsc_t *dsc, antenna_t which, int scale)
{
    int w = ANTENNA_W * scale, h = ANTENNA_H * scale;
    uint8_t *px = lv_malloc_zeroed((size_t)w * h);
    for (int y = 0; y < h; y++)
    {
        for (int x = 0; x < w; x++)
        {
            char c = antenna_art[y / scale][x / scale];
            bool on = c == '#' || (c == 'w' && which == ANTENNA_UP);
            if (which == ANTENNA_DOWN)
            {
                // Struck through, top right to bottom left
                int d = (w - 1 - x) * h - y * w;
                on = on || (d < 0 ? -d : d) <= scale * w;
            }
            px[y * w + x] = on ? 0xFF : 0;
        }
    }
    *dsc = (lv_image_dsc_t){
        .header = { .magic = LV_IMAGE_HEADER_MAGIC, .cf = LV_COLOR_FORMAT_A8, .w = w, .h = h, .stride = w },
        .data_size = (uint32_t)(w * h),
        .data = px,
    };
}

/* ----- The avatar ----- */

typedef enum
{
    LOOK_OFF,       // the channel's off
    LOOK_IDLE,
    LOOK_RX,
    LOOK_TX,
} look_t;

static int avatar_px;               // the pictures' size, from the phone
static uint16_t *nobody;            // the picture for no picture, avatar_px square
static uint16_t *avatar_pixels;     // what's on screen, avatar_px * AVATAR_SCALE square
static lv_image_dsc_t avatar_dsc;
static lv_obj_t *avatar_image;
static const uint16_t *baked_from;
static look_t baked_look = (look_t)-1;
static uint32_t baked_changes;

static void make_nobody(void)
{
    nobody = lv_malloc((size_t)avatar_px * avatar_px * 2);
    for (int y = 0; y < avatar_px; y++)
    {
        for (int x = 0; x < avatar_px; x++)
        {
            char c = nobody_art[y * NOBODY_PX / avatar_px][x * NOBODY_PX / avatar_px];
            nobody[y * avatar_px + x] = c == '#' ? 0xBDF7 : c == '+' ? 0x4208 : 0;    // light and dark grey
        }
    }
}

/* Draw src (RGB565, avatar_px square) on screen, AVATAR_SCALE times as big,
 * with every other row darker: in full color for RX and TX, and in dim
 * phosphor green while it's quiet. */
static void bake(const uint16_t *src, int src_px, look_t look)
{
    int out_px = avatar_px * AVATAR_SCALE;
    bool mono = look == LOOK_IDLE || look == LOOK_OFF;
    int level = look == LOOK_OFF ? 80 : look == LOOK_IDLE ? 150 : 256;
    const int tr = (PHOSPHOR_HEX >> 16) & 0xFF, tg = (PHOSPHOR_HEX >> 8) & 0xFF, tb = PHOSPHOR_HEX & 0xFF;
    for (int y = 0; y < out_px; y++)
    {
        // Each of the picture's pixels a block on screen: 2x2 for the phone's,
        // and 7x7 for those sent over the air, which look all the more retro
        const uint16_t *row = src + (y * src_px / out_px) * src_px;
        uint16_t *out = avatar_pixels + y * out_px;
        int l = (y % AVATAR_SCALE == AVATAR_SCALE - 1) ? level * SCANLINE / 256 : level;
        int last_x = -1;
        uint16_t p = 0;
        for (int x = 0; x < out_px; x++)
        {
            int sx = x * src_px / out_px;
            if (sx != last_x)
            {
                last_x = sx;
                uint16_t v = row[sx];
                int r = (v >> 11) << 3, g = ((v >> 5) & 0x3F) << 2, b = (v & 0x1F) << 3;
                if (mono)
                {
                    int luma = (r * 77 + g * 150 + b * 29) >> 8;
                    r = tr * luma >> 8;
                    g = tg * luma >> 8;
                    b = tb * luma >> 8;
                }
                r = r * l >> 8;
                g = g * l >> 8;
                b = b * l >> 8;
                p = (uint16_t)(((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3));
            }
            *out++ = p;
        }
    }
    lv_obj_invalidate(avatar_image);
}

/* Show an avatar: the phone's, in slot, or for one heard over direct comms
 * without one, the small one their board sent by name, if it has. */
static void show_avatar(int slot, const char *direct_name, look_t look)
{
    if (avatar_pixels == NULL)
    {
        return;
    }
    const uint16_t *src = comm_avatar(slot);
    int src_px = avatar_px;
    uint32_t changes = comm_avatar_changes();
    if (src == NULL && direct_name != NULL)
    {
        uint8_t version = 0;
        src = direct_avatar(direct_name, &version);
        src_px = DIRECT_AVATAR_PX;
        changes += version;
    }
    if (src == NULL)
    {
        src = nobody;
        src_px = avatar_px;
    }
    if (src != baked_from || look != baked_look || changes != baked_changes)
    {
        baked_from = src;
        baked_look = look;
        baked_changes = changes;
        bake(src, src_px, look);
    }
}

/* ----- The status screen ----- */

static lv_obj_t *status_page;
static lv_obj_t *tx_ring;           // round the edge, while it sends
static lv_obj_t *antenna;
static lv_obj_t *title;
static lv_obj_t *frame;             // round the avatar; holding it talks
static lv_obj_t *brackets[4];
static lv_obj_t *tag;               // TX, RX, or the mode
static lv_obj_t *name_label;
static lv_obj_t *transport_icon;    // by the name, while it sends
static lv_font_t name_font;         // the pixel font, with the theme's for what it hasn't got
static look_t look = (look_t)-1;
static antenna_t antenna_state = ANTENNA_COUNT;
static uint32_t pressed_since;      // when the avatar was first held, 0 if it isn't
static bool frame_talking;

static void set_look(look_t l)
{
    if (l == look)
    {
        return;
    }
    look = l;
    lv_color_t edge = l == LOOK_TX ? COLOR_HOT : l == LOOK_RX ? COLOR_PHOSPHOR : l == LOOK_IDLE ? COLOR_MID : COLOR_DIM;
    lv_obj_set_hidden(tx_ring, l != LOOK_TX);
    lv_obj_set_style_border_color(frame, edge, 0);
    lv_obj_set_style_border_width(frame, l == LOOK_TX ? ui_px(4) : l == LOOK_RX ? ui_px(3) : ui_px(2), 0);
    for (int i = 0; i < 4; i++)
    {
        lv_obj_set_style_border_color(brackets[i], edge, 0);
    }
    // The tag: lit up, dark on light, for TX and RX; an outline otherwise
    bool lit = l == LOOK_TX || l == LOOK_RX;
    lv_obj_set_style_bg_color(tag, lit ? edge : lv_color_black(), 0);
    lv_obj_set_style_border_color(tag, edge, 0);
    lv_obj_set_style_text_color(tag, lit ? lv_color_black() : edge, 0);
    lv_obj_set_style_text_color(name_label, lit ? edge : COLOR_MID, 0);
    lv_obj_set_style_text_color(title, l == LOOK_OFF ? COLOR_DIM : COLOR_MID, 0);
}

static void set_antenna(antenna_t a)
{
    if (a == antenna_state)
    {
        return;
    }
    antenna_state = a;
    lv_image_set_src(antenna, &antenna_icons[a]);
    lv_obj_set_style_image_recolor(antenna, a == ANTENNA_UP ? COLOR_PHOSPHOR : a == ANTENNA_NO_SERVER ? COLOR_WARN :
                                            COLOR_ALERT, 0);
}

static void show_status(void)
{
    bool on = comm_running() || direct_running();
    bool uplink = comm_phone_connected();
    comm_server_t server = comm_server();
    int hearing = comm_hearing_count();
    bool tx = comm_sending();

    look_t l = !on ? LOOK_OFF : tx ? LOOK_TX : hearing > 0 ? LOOK_RX : LOOK_IDLE;
    set_look(l);
    set_antenna(!uplink ? ANTENNA_DOWN : server == COMM_SERVER_CONNECTED ? ANTENNA_UP : ANTENNA_NO_SERVER);
    bool rx_direct = l == LOOK_RX && comm_hearing_transport(0) == COMM_TALK_DIRECT;
    show_avatar(l == LOOK_RX ? comm_hearing_avatar(0) : comm_own_avatar(), rx_direct ? comm_hearing_name(0) : NULL, l);

    bool rec = comm_recording();
    set_label(tag, rec ? "REC" : l == LOOK_TX ? "TX" : l == LOOK_RX ? "RX" : l == LOOK_OFF ? "OFF" :
                   comm_mode() == COMM_VOICE ? "VOX" : "PTT");

    // Under it: where it's sending, who's talking, or how things are
    char text[64];
    // The icon: where it's sending, or how the one talking is heard
    bool show_icon = (tx || hearing > 0) && !rec;
    int transport = tx ? (int)comm_talk_now() : comm_hearing_transport(0);
    if (show_icon && lv_image_get_src(transport_icon) != &transport_icons[transport])
    {
        lv_image_set_src(transport_icon, &transport_icons[transport]);
    }
    if (rec)
    {
        snprintf(text, sizeof(text), "RECORDING");
    }
    else if (tx)
    {
        // Who it's going to: the server's channel, the direct group, or one person
        snprintf(text, sizeof(text), "%s", comm_talk_to_name());
    }
    else if (comm_talk_refused())
    {
        snprintf(text, sizeof(text), "NOBODY HEARS");
    }
    else if (hearing > 0)
    {
        // The first, and how many more: the last may be "+2" for more still
        int more = hearing - 1;
        const char *last = comm_hearing_name(hearing - 1);
        if (hearing > 1 && last[0] == '+')
        {
            more += atoi(last + 1) - 1;
        }
        snprintf(text, sizeof(text), more > 0 ? "%s +%d" : "%s", comm_hearing_name(0), more);
    }
    else if (!on)
    {
        snprintf(text, sizeof(text), "COMMS OFF");
    }
    else if (!uplink && direct_running())
    {
        // Board to board: how many are about
        direct_peer_t peers[DIRECT_PEERS_MAX];
        int n = direct_peers(peers, DIRECT_PEERS_MAX);
        snprintf(text, sizeof(text), n == 0 ? "DIRECT" : "%d NEARBY", n);
    }
    else if (!uplink)
    {
        snprintf(text, sizeof(text), "NO UPLINK");
    }
    else if (server == COMM_SERVER_CONNECTING)
    {
        snprintf(text, sizeof(text), "LINKING...");
    }
    else if (server != COMM_SERVER_CONNECTED)
    {
        snprintf(text, sizeof(text), "NO SERVER");
    }
    else
    {
        int others = comm_server_others();
        snprintf(text, sizeof(text), others == 0 ? "ALONE" : "%d ONLINE", others);
    }
    if (lv_obj_is_hidden(transport_icon) == show_icon)
    {
        lv_obj_set_hidden(transport_icon, !show_icon);
        // Narrower with the icon, to keep inside the round screen
        lv_obj_set_style_max_width(name_label, show_icon ? ui_px(112) : ui_px(140), 0);
    }
    // The icon's color, as the line's: white-hot for TX, phosphor for RX
    static int icon_tx = -1;
    if (icon_tx != (int)tx)
    {
        icon_tx = tx;
        lv_obj_set_style_image_recolor(transport_icon, tx ? COLOR_HOT : COLOR_PHOSPHOR, 0);
    }
    set_label(name_label, text);
}

/* Hold the avatar to talk, once it's clear it isn't the start of a swipe:
 * scrolling takes the press away. Once it talks, the page holds still. */
static void update_frame_talk(uint32_t now)
{
    bool pressed = ui_current_page() == status_page && lv_obj_has_state(frame, LV_STATE_PRESSED);
    if (!pressed)
    {
        pressed_since = 0;
        if (frame_talking)
        {
            frame_talking = false;
            comm_set_talk(false);
            lv_obj_set_scroll_chain(frame, true);
        }
        return;
    }
    if (pressed_since == 0)
    {
        pressed_since = now | 1;
    }
    if (!frame_talking && (comm_running() || direct_running()) && now - pressed_since >= HOLD_TO_TALK_MS)
    {
        frame_talking = true;
        lv_obj_set_scroll_chain(frame, false);  // a swipe from here doesn't move the page now
        comm_set_talk(true);
    }
}

static lv_obj_t *add_bracket(lv_obj_t *parent, lv_align_t align, lv_border_side_t sides, int32_t off)
{
    lv_obj_t *b = lv_obj_create(parent);
    lv_obj_remove_style_all(b);
    lv_obj_set_size(b, ui_px(14), ui_px(14));
    lv_obj_set_style_border_width(b, LV_MAX(2, ui_px(2)), 0);
    lv_obj_set_style_border_side(b, sides, 0);
    lv_obj_set_clickable(b, false);
    bool left = align == LV_ALIGN_TOP_LEFT || align == LV_ALIGN_BOTTOM_LEFT;
    bool top = align == LV_ALIGN_TOP_LEFT || align == LV_ALIGN_TOP_RIGHT;
    lv_obj_align(b, align, left ? -off : off, top ? -off : off);
    return b;
}

static void add_status_page(ui_feature_t *feature)
{
    status_page = ui_feature_add_page(feature, "HiveMind", true);
    lv_obj_set_scrollable(status_page, false);

    tx_ring = lv_obj_create(status_page);
    lv_obj_remove_style_all(tx_ring);
    lv_obj_set_size(tx_ring, ui_px(234), ui_px(234));
    lv_obj_set_style_radius(tx_ring, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_border_width(tx_ring, ui_px(4), 0);
    lv_obj_set_style_border_color(tx_ring, COLOR_HOT, 0);
    lv_obj_set_clickable(tx_ring, false);
    lv_obj_center(tx_ring);

    // The top: the antenna, and "HiveMind" in the Terminal's letters
    lv_obj_t *top = lv_obj_create(status_page);
    lv_obj_remove_style_all(top);
    lv_obj_set_size(top, LV_SIZE_CONTENT, LV_SIZE_CONTENT);
    lv_obj_set_flex_flow(top, LV_FLEX_FLOW_ROW);
    lv_obj_set_flex_align(top, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_END, LV_FLEX_ALIGN_END);
    lv_obj_set_style_pad_column(top, ui_px(6), 0);
    lv_obj_set_clickable(top, false);
    lv_obj_align(top, LV_ALIGN_TOP_MID, 0, ui_px(20));
    int scale = LV_MAX(1, ui_px(3) / 2);
    for (int i = 0; i < ANTENNA_COUNT; i++)
    {
        make_antenna(&antenna_icons[i], (antenna_t)i, scale);
    }
    antenna = lv_image_create(top);
    lv_obj_set_style_image_recolor_opa(antenna, LV_OPA_COVER, 0);
    title = lv_label_create(top);
    lv_obj_set_style_text_font(title, &terminal_font_2, 0);
    lv_obj_set_style_text_letter_space(title, ui_px(2), 0);
    lv_label_set_text(title, "HiveMind");

    // The avatar, in a frame with corner brackets
    avatar_px = ui_px(AVATAR_DESIGN_PX) / AVATAR_SCALE;
    comm_set_avatar_size(avatar_px);
    int32_t shown = avatar_px * AVATAR_SCALE;
    frame = lv_obj_create(status_page);
    lv_obj_remove_style_all(frame);
    lv_obj_set_size(frame, shown + ui_px(10), shown + ui_px(10));
    lv_obj_set_style_bg_color(frame, lv_color_black(), 0);
    lv_obj_set_style_bg_opa(frame, LV_OPA_COVER, 0);
    lv_obj_set_overflow_visible(frame, true);
    lv_obj_set_clickable(frame, true);
    lv_obj_set_scrollable(frame, false);
    lv_obj_align(frame, LV_ALIGN_CENTER, 0, ui_px(-8));

    make_nobody();
    avatar_pixels = lv_malloc_zeroed((size_t)shown * shown * 2);
    avatar_dsc = (lv_image_dsc_t){
        .header = { .magic = LV_IMAGE_HEADER_MAGIC, .cf = LV_COLOR_FORMAT_RGB565, .w = shown, .h = shown,
                    .stride = shown * 2 },
        .data_size = (uint32_t)(shown * shown * 2),
        .data = (const uint8_t *)avatar_pixels,
    };
    avatar_image = lv_image_create(frame);
    lv_image_set_src(avatar_image, &avatar_dsc);
    lv_obj_center(avatar_image);

    int32_t off = ui_px(6);
    brackets[0] = add_bracket(frame, LV_ALIGN_TOP_LEFT, LV_BORDER_SIDE_TOP | LV_BORDER_SIDE_LEFT, off);
    brackets[1] = add_bracket(frame, LV_ALIGN_TOP_RIGHT, LV_BORDER_SIDE_TOP | LV_BORDER_SIDE_RIGHT, off);
    brackets[2] = add_bracket(frame, LV_ALIGN_BOTTOM_LEFT, LV_BORDER_SIDE_BOTTOM | LV_BORDER_SIDE_LEFT, off);
    brackets[3] = add_bracket(frame, LV_ALIGN_BOTTOM_RIGHT, LV_BORDER_SIDE_BOTTOM | LV_BORDER_SIDE_RIGHT, off);

    // TX, RX or the mode, on the frame's bottom edge
    tag = lv_label_create(status_page);     // not the frame's: that would cut it off
    lv_obj_set_style_text_font(tag, &terminal_font_3, 0);
    lv_obj_set_style_bg_opa(tag, LV_OPA_COVER, 0);
    lv_obj_set_style_border_width(tag, LV_MAX(1, ui_px(1)), 0);
    lv_obj_set_style_pad_hor(tag, ui_px(6), 0);
    lv_obj_set_style_pad_ver(tag, ui_px(2), 0);
    lv_label_set_text(tag, "");
    lv_obj_align(tag, LV_ALIGN_CENTER, 0, ui_px(-8) + (shown + ui_px(10)) / 2);

    name_font = terminal_font_3;
    name_font.fallback = LV_FONT_DEFAULT;
    // The name line: an icon for where it's sending, then the text
    lv_obj_t *row = lv_obj_create(status_page);
    lv_obj_remove_style_all(row);
    lv_obj_set_size(row, LV_SIZE_CONTENT, LV_SIZE_CONTENT);
    lv_obj_set_flex_flow(row, LV_FLEX_FLOW_ROW);
    lv_obj_set_flex_align(row, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_set_style_pad_column(row, ui_px(6), 0);
    lv_obj_set_clickable(row, false);
    lv_obj_align(row, LV_ALIGN_CENTER, 0, ui_px(80));
    int icon_scale = LV_MAX(1, ui_px(3) / 2);
    make_icon(&transport_icons[COMM_TALK_SERVER], cloud_art, 13, 7, icon_scale);
    make_icon(&transport_icons[COMM_TALK_DIRECT], radio_art, 9, 13, icon_scale);
    transport_icon = lv_image_create(row);
    lv_image_set_src(transport_icon, &transport_icons[COMM_TALK_SERVER]);
    lv_obj_set_style_image_recolor(transport_icon, COLOR_HOT, 0);
    lv_obj_set_style_image_recolor_opa(transport_icon, LV_OPA_COVER, 0);
    lv_obj_set_hidden(transport_icon, true);

    name_label = lv_label_create(row);
    lv_obj_set_style_text_font(name_label, &name_font, 0);
    // As wide as its text, up to what fits, and cut short with dots beyond
    lv_label_set_long_mode(name_label, LV_LABEL_LONG_MODE_DOTS);
    lv_obj_set_width(name_label, LV_SIZE_CONTENT);
    lv_obj_set_style_max_width(name_label, ui_px(140), 0);
    lv_label_set_text(name_label, "");

    show_status();
    ui_add_startup_choice(feature, status_page, "HiveMind", "comm");   // "comm" is what's saved
}

/* ----- Coming to the status screen by itself ----- */

static bool jumped;                 // came by itself, and will go back
static size_t back_feature, back_page;
static uint32_t wanted_at;          // when there was last a reason to be here

static void update_auto_show(uint32_t now)
{
    uint8_t show = settings_get()->comm_auto_show;
    bool want = ((show & SETTINGS_SHOW_SENDING) && comm_sending()) ||
                ((show & SETTINGS_SHOW_HEARING) && comm_hearing_count() > 0);
    if (want)
    {
        wanted_at = now;
        if (!jumped && ui_current_page() != status_page && !touching())
        {
            ui_current(&back_feature, &back_page);
            jumped = ui_show_page(status_page);
        }
    }
    else if (jumped && now - wanted_at >= RETURN_AFTER_MS && !touching())
    {
        jumped = false;
        if (ui_current_page() == status_page)
        {
            ui_show(back_feature, back_page);
        }
    }
}

/* ----- Comm Setup ----- */

static lv_obj_t *setup_page;
static lv_obj_t *mode_buttons;
static lv_obj_t *mute_switch;
static lv_obj_t *show_buttons;

static void show_setup(void)
{
    const settings_t *s = settings_get();
    ui_check_choice(mode_buttons, comm_mode());    // the phone can change it too
    ui_check_choice(show_buttons, s->comm_auto_show);
    if (mute_switch != NULL)
    {
        lv_obj_set_state(mute_switch, LV_STATE_CHECKED, s->comm_mute_speaker);
    }
}

static void mode_event_cb(lv_event_t *e)
{
    uint32_t selected = lv_buttonmatrix_get_selected_button(mode_buttons);
    if (selected < COMM_MODE_COUNT)
    {
        comm_set_mode((comm_mode_t)selected);
    }
}

static void options_event_cb(lv_event_t *e)
{
    // The choices are in the order of their bits: off, sending, hearing, both
    uint32_t show = lv_buttonmatrix_get_selected_button(show_buttons);
    if (show > (SETTINGS_SHOW_SENDING | SETTINGS_SHOW_HEARING))
    {
        show = settings_get()->comm_auto_show;
    }
    bool mute = mute_switch != NULL ? lv_obj_has_state(mute_switch, LV_STATE_CHECKED)
                                    : settings_get()->comm_mute_speaker;
    settings_set_comm_options(mute, (uint8_t)show);
}

static void add_setup_page(ui_feature_t *feature)
{
    setup_page = ui_feature_add_page(feature, "HiveMind Setup", false);
    lv_obj_set_scrollable(setup_page, false);

    lv_obj_t *t = lv_label_create(setup_page);
    lv_label_set_text(t, "HiveMind Setup");
    lv_obj_align(t, LV_ALIGN_TOP_MID, 0, ui_px(28));

    // Push to talk, or talk whenever it hears you
    static const char *const modes[] = { "Push to talk", "Voice", "" };
    // Without a speaker (the low-profile housing) there's none to silence,
    // and the rest close up
    bool speaker = settings_speaker_fitted();
    mode_buttons = ui_add_choices(setup_page, modes, ui_px(190), ui_px(36), ui_px(speaker ? -46 : -30));
    lv_obj_add_event_cb(mode_buttons, mode_event_cb, LV_EVENT_VALUE_CHANGED, NULL);

    mute_switch = NULL;
    if (speaker)
    {
        lv_obj_t *mute_label = lv_label_create(setup_page);
        lv_label_set_text(mute_label, "Speaker off\nwhile talking");
        lv_obj_align(mute_label, LV_ALIGN_CENTER, ui_px(-30), ui_px(2));
        mute_switch = lv_switch_create(setup_page);
        lv_obj_set_size(mute_switch, ui_px(56), ui_px(28));
        lv_obj_align(mute_switch, LV_ALIGN_CENTER, ui_px(64), ui_px(2));
        lv_obj_add_event_cb(mute_switch, options_event_cb, LV_EVENT_VALUE_CHANGED, NULL);
    }

    lv_obj_t *show_label = lv_label_create(setup_page);
    lv_label_set_text(show_label, "Show HiveMind while");
    lv_obj_set_style_text_color(show_label, COLOR_MUTED, 0);
    lv_obj_align(show_label, LV_ALIGN_CENTER, 0, ui_px(speaker ? 36 : 20));

    static const char *const shows[] = { "Off", "Talk", "Hear", "Both", "" };
    show_buttons = ui_add_choices(setup_page, shows, ui_px(176), ui_px(32), ui_px(speaker ? 64 : 48));
    lv_obj_add_event_cb(show_buttons, options_event_cb, LV_EVENT_VALUE_CHANGED, NULL);

    show_setup();
}

/* ----- The comm channel's own voice effect ----- */

static lv_obj_t *voice_page;
static lv_obj_t *voice_roller;

static void show_voice(void)
{
    // The first is the speaker's own; the rest are the presets
    uint32_t want = (uint32_t)(comm_voice_effect() + 1);
    if (!lv_obj_has_state(voice_roller, LV_STATE_PRESSED) && lv_roller_get_selected(voice_roller) != want)
    {
        lv_roller_set_selected(voice_roller, want, LV_ANIM_OFF);
    }
}

static void voice_roller_cb(lv_event_t *e)
{
    comm_set_voice_effect((int)lv_roller_get_selected(voice_roller) - 1);
}

static void add_voice_page(ui_feature_t *feature)
{
    voice_page = ui_feature_add_page(feature, "HiveMind Voice", false);
    lv_obj_set_scrollable(voice_page, false);

    lv_obj_t *t = lv_label_create(voice_page);
    lv_label_set_text(t, "HiveMind Voice Effect");
    lv_obj_align(t, LV_ALIGN_TOP_MID, 0, ui_px(28));

    size_t len = 32;
    for (size_t i = 0; i < voice_fx_preset_count(); i++)
    {
        len += strlen(voice_fx_preset_name(i)) + 1;
    }
    char *options = lv_malloc(len);
    // The first is the effect on the Voice page: the speaker's, where there's one
    snprintf(options, len, settings_speaker_fitted() ? "Same as speaker" : "As Voice page");
    for (size_t i = 0; i < voice_fx_preset_count(); i++)
    {
        strcat(options, "\n");
        strcat(options, voice_fx_preset_name(i));
    }
    voice_roller = lv_roller_create(voice_page);
    lv_roller_set_options(voice_roller, options, LV_ROLLER_MODE_NORMAL);
    lv_free(options);
    lv_roller_set_visible_row_count(voice_roller, 3);
    lv_obj_set_width(voice_roller, ui_px(160));
    lv_obj_align(voice_roller, LV_ALIGN_CENTER, 0, ui_px(-4));
    lv_obj_add_event_cb(voice_roller, voice_roller_cb, LV_EVENT_VALUE_CHANGED, NULL);

    lv_obj_t *hint = lv_label_create(voice_page);
    lv_label_set_text(hint, "What the hive hears.");
    lv_obj_set_style_text_align(hint, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_set_style_text_color(hint, COLOR_MUTED, 0);
    lv_obj_align(hint, LV_ALIGN_CENTER, 0, ui_px(74));

    show_voice();
}

/* ----- Direct comms ----- */

static lv_obj_t *direct_page;
static lv_obj_t *direct_switch;
static lv_obj_t *direct_group_label;
static lv_obj_t *direct_peers_label;
static lv_obj_t *talk_to_label;
static lv_obj_t *talk_to_buttons;

static void show_direct(void)
{
    bool on = direct_running();
    lv_obj_set_state(direct_switch, LV_STATE_CHECKED, on);
    // Who talking goes to: the app can change it too, to one person
    comm_to_t to = comm_talk_to();
    if (to == COMM_TO_PERSON)
    {
        lv_buttonmatrix_clear_button_ctrl_all(talk_to_buttons, LV_BUTTONMATRIX_CTRL_CHECKED);
        char who[16 + COMM_NAME_MAX];
        snprintf(who, sizeof(who), "Talk to: %s", comm_talk_to_name());
        set_label(talk_to_label, who);
    }
    else
    {
        ui_check_choice(talk_to_buttons, to == COMM_TO_DIRECT ? 1 : 0);
        set_label(talk_to_label, "Talk to");
    }
    char text[160];
    snprintf(text, sizeof(text), "%s, freq %u%s\nAs: %s", direct_group_name(), direct_channel(),
             direct_long_range() ? ", LR" : "", direct_own_name());
    set_label(direct_group_label, text);
    if (!on)
    {
        set_label(direct_peers_label, "Board to board, over the\nradio: no signal needed");
        return;
    }
    direct_peer_t peers[DIRECT_PEERS_MAX];
    int n = direct_peers(peers, DIRECT_PEERS_MAX);
    if (n == 0)
    {
        set_label(direct_peers_label, "No boards heard yet");
        return;
    }
    // The strongest few, with bars for how well they're heard
    size_t at = 0;
    for (int i = 0; i < n && i < 2; i++)
    {
        int r = peers[i].rssi;
        const char *bars = r > -60 ? "||||" : r > -70 ? "|||" : r > -80 ? "||" : "|";
        at += (size_t)snprintf(text + at, sizeof(text) - at, "%s%s %s%s", i ? "\n" : "", peers[i].name, bars,
                               peers[i].talking ? " " LV_SYMBOL_AUDIO : "");
        if (at >= sizeof(text))
        {
            break;
        }
    }
    if (n > 2 && at < sizeof(text))
    {
        snprintf(text + at, sizeof(text) - at, " +%d", n - 2);
    }
    set_label(direct_peers_label, text);
}

static void direct_switch_cb(lv_event_t *e)
{
    if (lv_obj_has_state(direct_switch, LV_STATE_CHECKED))
    {
        if (!direct_start())
        {
            set_label(direct_peers_label, "The radio didn't start");
        }
    }
    else
    {
        direct_stop();
    }
    show_direct();
}

static void talk_to_cb(lv_event_t *e)
{
    uint32_t selected = lv_buttonmatrix_get_selected_button(talk_to_buttons);
    if (selected < COMM_TALK_COUNT)
    {
        comm_talk_to_channel((comm_transport_t)selected);
    }
}

static void add_direct_page(ui_feature_t *feature)
{
    direct_page = ui_feature_add_page(feature, "Direct", false);
    lv_obj_set_scrollable(direct_page, false);

    lv_obj_t *t = lv_label_create(direct_page);
    lv_label_set_text(t, "Direct");
    lv_obj_align(t, LV_ALIGN_TOP_MID, 0, ui_px(28));

    direct_switch = lv_switch_create(direct_page);
    lv_obj_set_size(direct_switch, ui_px(64), ui_px(32));
    lv_obj_align(direct_switch, LV_ALIGN_CENTER, 0, ui_px(-60));

    // Who talking goes to: the server's channel or the direct one, from here, or
    // one person, from the app
    talk_to_label = lv_label_create(direct_page);
    lv_label_set_text(talk_to_label, "Talk to");
    lv_label_set_long_mode(talk_to_label, LV_LABEL_LONG_DOT);
    lv_obj_set_width(talk_to_label, ui_px(170));
    lv_obj_set_style_text_align(talk_to_label, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_set_style_text_color(talk_to_label, COLOR_MUTED, 0);
    lv_obj_align(talk_to_label, LV_ALIGN_CENTER, 0, ui_px(-32));
    static const char *const channels[] = { "Server", "Direct", "" };
    talk_to_buttons = ui_add_choices(direct_page, channels, ui_px(170), ui_px(30), ui_px(-9));
    lv_obj_add_event_cb(talk_to_buttons, talk_to_cb, LV_EVENT_VALUE_CHANGED, NULL);
    lv_obj_add_event_cb(direct_switch, direct_switch_cb, LV_EVENT_VALUE_CHANGED, NULL);

    direct_group_label = lv_label_create(direct_page);
    lv_label_set_text(direct_group_label, "");
    lv_obj_set_style_text_align(direct_group_label, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_align(direct_group_label, LV_ALIGN_CENTER, 0, ui_px(30));

    direct_peers_label = lv_label_create(direct_page);
    lv_label_set_text(direct_peers_label, "");
    lv_obj_set_style_text_align(direct_peers_label, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_set_style_text_color(direct_peers_label, COLOR_MUTED, 0);
    lv_obj_align(direct_peers_label, LV_ALIGN_CENTER, 0, ui_px(72));

    show_direct();
}

/* ----- The talk button ----- */

static lv_obj_t *button_page;
static lv_obj_t *button_title;
static lv_obj_t *button_status;
static lv_obj_t *button_action;
static lv_obj_t *button_action_label;
static lv_obj_t *button_hint;

static void show_button(void)
{
    talk_button_state_t st = talk_button_state();
    const char *status = "";
    const char *action = "Pair a button";
    const char *hint = "A Bluetooth camera remote,\nto hold to talk";
    switch (st)
    {
    case TALK_BUTTON_NONE:
        break;
    case TALK_BUTTON_OFF:
        status = "Works while the\nPhone App is on";
        action = "Forget it";
        hint = "";
        break;
    case TALK_BUTTON_WAITING:
        status = "Asleep: press it to wake it";
        action = "Forget it";
        hint = "";
        break;
    case TALK_BUTTON_CONNECTING:
        status = "Connecting...";
        action = "Forget it";
        hint = "";
        break;
    case TALK_BUTTON_CONNECTED:
        status = talk_button_held() ? LV_SYMBOL_AUDIO "  Pressed" : LV_SYMBOL_BLUETOOTH "  Connected";
        action = "Forget it";
        hint = "Hold it to talk";
        break;
    case TALK_BUTTON_FINDING:
        status = "Looking...";
        action = "Cancel";
        hint = "Put the button in pairing mode:\nswitch it on, or hold it down";
        break;
    case TALK_BUTTON_PAIRING:
        status = "Pairing...";
        action = "Cancel";
        hint = "";
        break;
    case TALK_BUTTON_NOT_FOUND:
        status = "No button found";
        action = "OK";
        hint = "Is it in pairing mode?";
        break;
    case TALK_BUTTON_FAILED:
        status = "Pairing didn't work";
        action = "OK";
        hint = "Try it again from pairing mode";
        break;
    }
    bool named = st != TALK_BUTTON_NONE && st != TALK_BUTTON_FINDING && st != TALK_BUTTON_NOT_FOUND;
    set_label(button_title, named ? talk_button_name() : "Talk Button");
    set_label(button_status, status);
    set_label(button_action_label, action);
    set_label(button_hint, hint);
}

static void button_action_cb(lv_event_t *e)
{
    switch (talk_button_state())
    {
    case TALK_BUTTON_NONE:
        if (!talk_button_pair())
        {
            set_label(button_hint, "Bluetooth didn't start");
            return;
        }
        break;
    case TALK_BUTTON_FINDING:
    case TALK_BUTTON_PAIRING:
    case TALK_BUTTON_NOT_FOUND:
    case TALK_BUTTON_FAILED:
        talk_button_cancel();
        break;
    default:
        talk_button_forget();
        break;
    }
    show_button();
}

static void add_button_page(ui_feature_t *feature)
{
    button_page = ui_feature_add_page(feature, "Talk Button", false);
    lv_obj_set_scrollable(button_page, false);

    button_title = lv_label_create(button_page);
    lv_label_set_text(button_title, "Talk Button");
    lv_obj_align(button_title, LV_ALIGN_TOP_MID, 0, ui_px(28));

    button_status = lv_label_create(button_page);
    lv_label_set_text(button_status, "");
    lv_obj_set_style_text_align(button_status, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_align(button_status, LV_ALIGN_CENTER, 0, ui_px(-50));

    button_action = lv_button_create(button_page);
    lv_obj_set_size(button_action, ui_px(150), ui_px(40));
    lv_obj_set_style_radius(button_action, LV_RADIUS_CIRCLE, 0);
    lv_obj_align(button_action, LV_ALIGN_CENTER, 0, 0);
    lv_obj_add_event_cb(button_action, button_action_cb, LV_EVENT_CLICKED, NULL);
    button_action_label = lv_label_create(button_action);
    lv_label_set_text(button_action_label, "");
    lv_obj_center(button_action_label);

    button_hint = lv_label_create(button_page);
    lv_label_set_text(button_hint, "");
    lv_obj_set_style_text_align(button_hint, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_set_style_text_color(button_hint, COLOR_MUTED, 0);
    lv_obj_align(button_hint, LV_ALIGN_CENTER, 0, ui_px(60));

    show_button();
}

/* ----- ----- */

static void update_timer_cb(lv_timer_t *t)
{
    uint32_t now = lv_tick_get();
    update_auto_show(now);
    update_frame_talk(now);
    lv_obj_t *page = ui_current_page();
    if (page == status_page)
    {
        show_status();
    }
    else if (page == setup_page)
    {
        show_setup();
    }
    else if (page == button_page)
    {
        show_button();
    }
    else if (page != NULL && page == direct_page)
    {
        show_direct();
    }
    else if (page != NULL && page == voice_page)
    {
        show_voice();
    }
}

static void on_navigate(void)
{
    lv_obj_t *page = ui_current_page();
    if (jumped && page != status_page)
    {
        jumped = false;     // gone somewhere else: stay there
    }
    if (page == status_page)
    {
        show_status();
    }
}

static bool build(ui_feature_t *feature)
{
    if (!comm_available())
    {
        return false;
    }
    add_status_page(feature);
    add_setup_page(feature);
    if (settings_speaker_fitted())
    {
        add_voice_page(feature);    // without a speaker, the Voice page's effect is HiveMind's
    }
    if (direct_available())
    {
        add_direct_page(feature);
    }
    add_button_page(feature);
    lv_timer_create(update_timer_cb, UPDATE_MS, NULL);
    return true;
}
