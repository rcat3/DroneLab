/*
 * The virtual unit: the firmware's core/ on a computer (see README.md)
 */

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "app.h"
#include "host.h"

host_options_t host_options = { .unit = 1, .scale = 1 };

/* Ctrl-C, or being told to stop: take the app's socket away first */
static void stop(int sig)
{
    host_peer_close();
    _exit(0);
}

static void usage(const char *name)
{
    printf("Usage: %s [options]\n"
           "\n"
           "  --unit N       be virtual unit N (1 and up), with its own settings and socket\n"
           "  --sdcard DIR   use DIR as the SD card, for images and sounds\n"
           "  --scale N      show the screen N times as big\n"
           "  --no-mic       don't use the microphone\n"
           "  --no-speaker   don't play sound\n"
           "\n"
           "Keys in the window: B is the BOOT button, F12 takes a screenshot (PWR and BOOT).\n",
           name);
}

int main(int argc, char **argv)
{
    host_options.argv = argv;
    for (int i = 1; i < argc; i++)
    {
        const char *a = argv[i];
        if (strcmp(a, "--unit") == 0 && i + 1 < argc)
        {
            host_options.unit = atoi(argv[++i]);
        }
        else if (strcmp(a, "--sdcard") == 0 && i + 1 < argc)
        {
            host_options.sdcard = argv[++i];
        }
        else if (strcmp(a, "--scale") == 0 && i + 1 < argc)
        {
            host_options.scale = atoi(argv[++i]);
        }
        else if (strcmp(a, "--no-mic") == 0)
        {
            host_options.no_mic = true;
        }
        else if (strcmp(a, "--no-speaker") == 0)
        {
            host_options.no_speaker = true;
        }
        else
        {
            usage(argv[0]);
            return strcmp(a, "--help") == 0 || strcmp(a, "-h") == 0 ? 0 : 2;
        }
    }
    if (host_options.unit < 1 || host_options.unit > 99)
    {
        fprintf(stderr, "--unit is 1 to 99\n");
        return 2;
    }
    if (host_options.scale < 1 || host_options.scale > 4)
    {
        fprintf(stderr, "--scale is 1 to 4\n");
        return 2;
    }

    // A write to the app after it's gone fails, rather than stopping us
    signal(SIGPIPE, SIG_IGN);
    signal(SIGINT, stop);
    signal(SIGTERM, stop);
    setvbuf(stdout, NULL, _IOLBF, 0);

    app_run();
    return 1;
}
