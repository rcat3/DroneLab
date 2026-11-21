#ifndef RCAT_UTF8_H
#define RCAT_UTF8_H

#include <stddef.h>
#include <string.h>

/*
 * A name cut to fit a buffer can end partway through a character that takes
 * more than one byte, like the hexagon some drones use (U+2B21, three bytes):
 * that would show as junk. Drop what's left of such a character.
 */
static inline void utf8_trim(char *s)
{
    size_t n = strlen(s);
    size_t start = n;
    // Back over continuation bytes (10xxxxxx) to the character's first byte
    while (start > 0 && ((unsigned char)s[start - 1] & 0xC0) == 0x80 && n - start < 3)
    {
        start--;
    }
    if (start == 0)
    {
        s[0] = '\0';    // only continuation bytes: nothing to keep
        return;
    }
    unsigned char lead = (unsigned char)s[start - 1];
    size_t want = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1;
    if (want > 1 && n - (start - 1) < want)
    {
        s[start - 1] = '\0';
    }
}

#endif
