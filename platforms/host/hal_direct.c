/*
 * Direct comms for virtual units: where the boards broadcast over ESP-NOW,
 * these send UDP multicast, to the other virtual units on this computer and
 * on the local network. It's for trying direct comms out, and developing it,
 * without the boards: a real unit doesn't hear them, and they don't hear it.
 *
 * Each broadcast goes out with a short header: a marker, the channel it was
 * sent on, and which unit sent it, so a unit leaves out its own and only
 * hears those on its channel, as the radio would.
 */

#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include "hal.h"
#include "host.h"

#define GROUP           "239.255.68.76"     // site-local multicast
#define PORT            47268
#define MARKER          "DLd1"
#define HEADER          (4 + 1 + 4)         // marker, channel, sender
#define QUEUE           48                  // the board keeps a few dozen
#define RSSI            (-40)               // as strong as a board right beside it

typedef struct
{
    uint8_t len;
    int8_t rssi;
    uint8_t data[RCAT_HAL_DIRECT_MAX];
} direct_msg_t;

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static direct_msg_t queue[QUEUE];
static size_t head, count;

static int sock = -1;
static bool thread_started;
static atomic_bool on;
static atomic_int channel = 6;          // what it sends on: the hotspot's, as on the boards
static atomic_int listening = 0;        // a channel it's listening on for a moment, or 0
static uint32_t self;                   // this unit's sender number
static struct sockaddr_in group_addr;

static void *receive_thread(void *arg)
{
    uint8_t buf[HEADER + RCAT_HAL_DIRECT_MAX + 1];
    while (1)
    {
        ssize_t n = recv(sock, buf, sizeof(buf), 0);
        if (n < 0)
        {
            if (errno != EINTR)
            {
                rcat_hal_delay_ms(100);
            }
            continue;
        }
        if (!on || n <= HEADER || n > HEADER + RCAT_HAL_DIRECT_MAX || memcmp(buf, MARKER, 4) != 0)
        {
            continue;
        }
        uint32_t sender;
        memcpy(&sender, buf + 5, 4);
        int heard_on = listening != 0 ? listening : channel;
        if (sender == self || buf[4] != heard_on)
        {
            continue;
        }
        size_t len = (size_t)n - HEADER;
        pthread_mutex_lock(&lock);
        size_t slot = (head + count) % QUEUE;
        if (count == QUEUE)
        {
            head = (head + 1) % QUEUE;      // drop the oldest
        }
        else
        {
            count++;
        }
        queue[slot].len = (uint8_t)len;
        queue[slot].rssi = RSSI;
        memcpy(queue[slot].data, buf + HEADER, len);
        pthread_mutex_unlock(&lock);
    }
    return NULL;
}

static bool open_socket(void)
{
    int fd = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (fd < 0)
    {
        return false;
    }
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, sizeof(yes));     // several units on one computer
    struct sockaddr_in any = { .sin_family = AF_INET, .sin_port = htons(PORT), .sin_addr.s_addr = htonl(INADDR_ANY) };
    if (bind(fd, (struct sockaddr *)&any, sizeof(any)) != 0)
    {
        fprintf(stderr, "Direct comms: couldn't take port %d: %s\n", PORT, strerror(errno));
        close(fd);
        return false;
    }
    struct ip_mreq join = { .imr_interface.s_addr = htonl(INADDR_ANY) };
    inet_pton(AF_INET, GROUP, &join.imr_multiaddr);
    if (setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &join, sizeof(join)) != 0)
    {
        // No network: the units on this computer can still hear each other
        // over the loopback interface, if it takes multicast
        join.imr_interface.s_addr = htonl(INADDR_LOOPBACK);
        if (setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &join, sizeof(join)) != 0)
        {
            fprintf(stderr, "Direct comms: couldn't join the multicast group: %s\n", strerror(errno));
            close(fd);
            return false;
        }
        struct in_addr lo = { .s_addr = htonl(INADDR_LOOPBACK) };
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &lo, sizeof(lo));
    }
    unsigned char ttl = 1, loop = 1;        // the local network only, and this computer too
    setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, sizeof(ttl));
    setsockopt(fd, IPPROTO_IP, IP_MULTICAST_LOOP, &loop, sizeof(loop));

    group_addr = (struct sockaddr_in){ .sin_family = AF_INET, .sin_port = htons(PORT) };
    inet_pton(AF_INET, GROUP, &group_addr.sin_addr);
    sock = fd;
    return true;
}

bool rcat_hal_direct_start(void)
{
    if (!thread_started)
    {
        while (self == 0)
        {
            self = rcat_hal_random();
        }
        if (!open_socket())
        {
            return false;
        }
        pthread_t thread;
        if (pthread_create(&thread, NULL, receive_thread, NULL) != 0)
        {
            return false;
        }
        pthread_detach(thread);
        pthread_setname_np(thread, "direct");
        thread_started = true;
    }
    on = true;
    printf("Direct comms on, channel %d, over UDP multicast %s:%d\n", (int)channel, GROUP, PORT);
    return true;
}

void rcat_hal_direct_stop(void)
{
    on = false;
    pthread_mutex_lock(&lock);
    count = 0;
    pthread_mutex_unlock(&lock);
}

void rcat_hal_direct_set_radio(uint8_t ch, bool long_range)
{
    // Long Range makes no odds here: the network carries it all the same
    channel = (ch == 1 || ch == 6 || ch == 11) ? ch : 6;
}

bool rcat_hal_direct_listen_on(uint8_t ch)
{
    if (!on)
    {
        return false;
    }
    listening = ch;
    return true;
}

bool rcat_hal_direct_send(const void *data, size_t len)
{
    if (!on || len == 0 || len > RCAT_HAL_DIRECT_MAX)
    {
        return false;
    }
    uint8_t buf[HEADER + RCAT_HAL_DIRECT_MAX];
    memcpy(buf, MARKER, 4);
    buf[4] = (uint8_t)channel;
    memcpy(buf + 5, &self, 4);
    memcpy(buf + HEADER, data, len);
    return sendto(sock, buf, HEADER + len, MSG_DONTWAIT, (struct sockaddr *)&group_addr, sizeof(group_addr)) ==
           (ssize_t)(HEADER + len);
}

size_t rcat_hal_direct_receive(void *data, size_t max, int8_t *rssi)
{
    size_t len = 0;
    pthread_mutex_lock(&lock);
    if (count > 0)
    {
        direct_msg_t *m = &queue[head];
        len = m->len < max ? m->len : max;
        memcpy(data, m->data, len);
        if (rssi != NULL)
        {
            *rssi = m->rssi;
        }
        head = (head + 1) % QUEUE;
        count--;
    }
    pthread_mutex_unlock(&lock);
    return len;
}
