#ifndef RCAT_REMOTE_H
#define RCAT_REMOTE_H

/*
 * Phone remote: the board runs a WiFi hotspot of its own, and a phone that
 * joins it gets a web page that runs the display: which page it shows, its
 * brightness, rotation and startup page, the Lovense devices (their motors,
 * patterns, reactions and Stop), the voice ring, the voice effect and the
 * sound player, and messages for the Terminal. It's switched on in Settings,
 * or at power-up if settings_t's remote_autostart is set.
 *
 * Joining is meant to be easy: the screen shows a QR code that a phone's
 * camera turns into "join this network", and once it's joined, the phone
 * opens the page by itself, as it does for a hotel's WiFi sign-in. Failing
 * that, the page is at http://192.168.4.1.
 *
 * The hotspot's name and password are made up the first time, and kept. A
 * new password (remote_new_password) shuts out anyone who had the old one.
 *
 * Everything runs from remote_poll(), on the UI loop, like the Lovense
 * connections, so the page and the screen change the same things and each
 * shows what the other did.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* True on boards with WiFi. */
bool remote_available(void);

/* Start or stop the hotspot and the page. Returns false if it couldn't
 * start. */
bool remote_start(void);
void remote_stop(void);
bool remote_running(void);

/* The hotspot's name and password, and what a phone's camera needs to join
 * it (for a QR code). */
const char *remote_ssid(void);
const char *remote_password(void);
const char *remote_join_text(void);

/* Make up a new password. If it's running, it restarts, and phones that have
 * joined are dropped. */
void remote_new_password(void);

/* How many phones have joined. */
int remote_phones(void);

/* Answer the phones. Call every 50 ms or so with a millisecond clock. */
void remote_poll(uint32_t now_ms);

/* The page itself, for the app to show (see comm.h). NULL on boards without
 * the remote. */
const char *remote_page_html(size_t *len);

/* Answer one of the page's API requests, from somewhere other than the
 * hotspot: the app, over the comm channel's Bluetooth link (see comm.h).
 * method is "GET" or "POST", and target the path and query, like
 * "/api/voice?p=3". Writes the JSON answer to out, and returns its length,
 * or -1 if there's no such request. Works whether the hotspot's on or not.
 * Call it from the UI loop.
 *
 * Besides the page's own, GET /api/comm answers the comm channel's settings,
 * {"available", "mode", "mute" (the speaker while it sends), "show" (when to
 * come to the Comm screen: SETTINGS_SHOW_* bits), "voice" (its own voice
 * effect, -1 for the speaker's), "voices" (the effects' names), "talk"
 * (comm_transport_t, as chosen), "talk_now" (where talking goes now)}, and
 * POST /api/comm?m=&mute=&show=&voice=&talk= changes any of them and answers
 * the same. With direct comms (see
 * direct.h), the answer has "direct": {"on", "keyed" (1 for a group with a
 * key, 0 for the open group), "group" (its name), "name" (this board's),
 * "id" (the group's id, 8 hex digits)},
 * and POST takes direct=0 or 1, and key= (32 hex digits, or empty for the
 * open group) with group= and name=. */
int remote_api(const char *method, const char *target, const char *body, size_t body_len, char *out, size_t cap);

#endif
