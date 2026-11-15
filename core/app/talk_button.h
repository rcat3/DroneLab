#ifndef RCAT_TALK_BUTTON_H
#define RCAT_TALK_BUTTON_H

#include <stdbool.h>
#include <stdint.h>

/*
 * The comm channel's talk button: a Bluetooth LE remote, like a camera
 * shutter remote, paired with the board. While a key on it is held, the comm
 * channel talks, in either mode (see comm.h).
 *
 * Pairing looks for HID devices in pairing mode and pairs with the nearest.
 * The pairing is kept, and the board connects to the button whenever the
 * comm channel's on and the button's awake: a press wakes it, and that press
 * counts.
 */

typedef enum
{
    TALK_BUTTON_NONE,           // none paired
    TALK_BUTTON_OFF,            // paired; the comm channel's off
    TALK_BUTTON_WAITING,        // waiting for it to wake up
    TALK_BUTTON_CONNECTING,
    TALK_BUTTON_CONNECTED,
    TALK_BUTTON_FINDING,        // pairing: looking for one in pairing mode
    TALK_BUTTON_PAIRING,        // pairing with the one it found
    TALK_BUTTON_NOT_FOUND,      // pairing found nothing
    TALK_BUTTON_FAILED,         // pairing didn't work
} talk_button_state_t;

/* Start using the paired button, if there is one: the comm channel's on. */
void talk_button_start(void);
void talk_button_stop(void);

/* Find a button in pairing mode and pair with it, replacing any other. */
bool talk_button_pair(void);
void talk_button_cancel(void);

/* Forget the paired button. */
void talk_button_forget(void);

/* Drive pairing along. Call it from the UI loop a few times a second. */
void talk_button_poll(uint32_t now_ms);

talk_button_state_t talk_button_state(void);

/* The paired (or pairing) button's name. */
const char *talk_button_name(void);

/* True while a key on it is held. Safe to call from any task. */
bool talk_button_held(void);

#endif
