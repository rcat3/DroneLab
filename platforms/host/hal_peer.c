/*
 * The virtual unit's link to the app: where a board has its Bluetooth
 * peripheral, a Unix socket at $XDG_RUNTIME_DIR/dronelab-unit.sock
 * (dronelab-unit-2.sock for unit 2, ...), carrying the same messages, each
 * after its length in 2 bytes, little-endian. See "Virtual units" in
 * app/linux/README.md.
 *
 * Only the computer's user can reach the runtime folder, so there's no
 * pairing: an app that's connected is as good as a phone that's paired and
 * has turned notifications on. One app at a time; another is turned away,
 * with an empty message first to say the unit's in use. While an app's
 * connected, an empty file beside the socket (dronelab-unit.sock.inuse)
 * says so to other apps looking for units, without their connecting.
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/eventfd.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#include "hal.h"
#include "host.h"

#define OUT_BUFFER      (64 * 1024)     // what's waiting to go to the app

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_t thread;
static bool thread_started;
static int wake_fd = -1;                // tells the thread something's changed
static atomic_bool wanted;              // between start and stop
static int listen_fd = -1;              // the thread's own
static atomic_int client_fd = -1;
static char path[sizeof(((struct sockaddr_un *)0)->sun_path)];
static char inuse_path[sizeof(path) + 8];

// From the app: whole messages, the oldest dropped when it's full
static uint8_t in_msgs[RCAT_HAL_BLE_PEER_MSGS][RCAT_HAL_BLE_PEER_MSG_MAX];
static uint8_t in_len[RCAT_HAL_BLE_PEER_MSGS];
static size_t in_head, in_count;

// To the app, framed
static uint8_t out_buf[OUT_BUFFER];
static size_t out_len;

// A message coming in, in pieces
static uint8_t partial[2 + RCAT_HAL_BLE_PEER_MSG_MAX];
static size_t partial_len;

static void wake(void)
{
    uint64_t one = 1;
    if (wake_fd >= 0 && write(wake_fd, &one, sizeof(one)) < 0)
    {
        // it's awake already if the counter's full
    }
}

static bool socket_path(char *out, size_t len)
{
    const char *runtime = getenv("XDG_RUNTIME_DIR");
    if (runtime == NULL || runtime[0] != '/')
    {
        fprintf(stderr, "XDG_RUNTIME_DIR isn't set, so there's nowhere for the app's socket\n");
        return false;
    }
    int n = host_options.unit == 1 ? snprintf(out, len, "%s/dronelab-unit.sock", runtime)
                                   : snprintf(out, len, "%s/dronelab-unit-%d.sock", runtime, host_options.unit);
    return n > 0 && (size_t)n < len;
}

/* Say whether an app's connected, for other apps' lists of units. */
static void mark_in_use(bool in_use)
{
    if (inuse_path[0] == '\0')
    {
        return;
    }
    if (in_use)
    {
        int f = open(inuse_path, O_WRONLY | O_CREAT | O_CLOEXEC, 0600);
        if (f >= 0)
        {
            close(f);
        }
    }
    else
    {
        unlink(inuse_path);
    }
}

/* Listen on the socket, unless another unit already is. */
static int listen_on(const char *p)
{
    struct sockaddr_un addr = { .sun_family = AF_UNIX };
    snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", p);

    // One left behind by a unit that stopped can go; one that answers can't.
    int probe = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (probe >= 0)
    {
        bool taken = connect(probe, (struct sockaddr *)&addr, sizeof(addr)) == 0;
        close(probe);
        if (taken)
        {
            fprintf(stderr, "Virtual unit %d is already running (%s): try --unit %d\n", host_options.unit, p,
                    host_options.unit + 1);
            return -1;
        }
    }
    unlink(p);

    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    if (fd < 0)
    {
        return -1;
    }
    mode_t old = umask(0077);
    int bound = bind(fd, (struct sockaddr *)&addr, sizeof(addr));
    umask(old);
    if (bound != 0 || listen(fd, 2) != 0)
    {
        fprintf(stderr, "Couldn't listen on %s: %s\n", p, strerror(errno));
        close(fd);
        return -1;
    }
    mark_in_use(false);     // left by a unit that stopped
    printf("Waiting for the app on %s\n", p);
    return fd;
}

static void drop_client(const char *why)
{
    pthread_mutex_lock(&lock);
    int fd = client_fd;
    client_fd = -1;
    out_len = 0;
    partial_len = 0;
    pthread_mutex_unlock(&lock);
    if (fd >= 0)
    {
        close(fd);
        mark_in_use(false);
        printf("App disconnected%s%s\n", why != NULL ? ": " : "", why != NULL ? why : "");
    }
}

/* Take in what the app's sent, a message at a time. False if it's gone, or
 * sent something that isn't a message. */
static bool read_client(int fd)
{
    uint8_t buf[4096];
    ssize_t n = recv(fd, buf, sizeof(buf), MSG_DONTWAIT);
    if (n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR))
    {
        return false;
    }
    for (ssize_t i = 0; i < n; i++)
    {
        partial[partial_len++] = buf[i];
        if (partial_len < 2)
        {
            continue;
        }
        size_t len = partial[0] | (size_t)partial[1] << 8;
        if (len == 0 || len > RCAT_HAL_BLE_PEER_MSG_MAX)
        {
            return false;
        }
        if (partial_len < 2 + len)
        {
            continue;
        }
        pthread_mutex_lock(&lock);
        size_t slot = (in_head + in_count) % RCAT_HAL_BLE_PEER_MSGS;
        if (in_count == RCAT_HAL_BLE_PEER_MSGS)
        {
            in_head = (in_head + 1) % RCAT_HAL_BLE_PEER_MSGS;     // drop the oldest
        }
        else
        {
            in_count++;
        }
        memcpy(in_msgs[slot], partial + 2, len);
        in_len[slot] = (uint8_t)len;
        pthread_mutex_unlock(&lock);
        partial_len = 0;
    }
    return true;
}

/* Send what's waiting, as much as the socket takes. */
static bool write_client(int fd)
{
    pthread_mutex_lock(&lock);
    bool ok = true;
    if (out_len > 0)
    {
        ssize_t n = send(fd, out_buf, out_len, MSG_DONTWAIT | MSG_NOSIGNAL);
        if (n > 0)
        {
            memmove(out_buf, out_buf + n, out_len - (size_t)n);
            out_len -= (size_t)n;
        }
        else if (n < 0 && errno != EAGAIN && errno != EINTR)
        {
            ok = false;
        }
    }
    pthread_mutex_unlock(&lock);
    return ok;
}

static void *peer_thread(void *arg)
{
    while (1)
    {
        if (wanted && listen_fd < 0)
        {
            listen_fd = listen_on(path);
            if (listen_fd < 0)
            {
                wanted = false;
            }
        }
        else if (!wanted && listen_fd >= 0)
        {
            drop_client(NULL);
            close(listen_fd);
            listen_fd = -1;
            unlink(path);
        }

        int fd = client_fd;
        pthread_mutex_lock(&lock);
        bool sending = out_len > 0;
        pthread_mutex_unlock(&lock);
        struct pollfd fds[3] = {
            { .fd = wake_fd, .events = POLLIN },
            { .fd = listen_fd, .events = POLLIN },
            { .fd = fd, .events = POLLIN | (sending ? POLLOUT : 0) },
        };
        if (poll(fds, 3, 1000) < 0)
        {
            continue;
        }
        if (fds[0].revents & POLLIN)
        {
            uint64_t count;
            if (read(wake_fd, &count, sizeof(count)) < 0)
            {
                // nothing to clear
            }
        }
        if (listen_fd >= 0 && (fds[1].revents & POLLIN))
        {
            int c = accept4(listen_fd, NULL, NULL, SOCK_CLOEXEC | SOCK_NONBLOCK);
            if (c >= 0)
            {
                if (client_fd >= 0)
                {
                    // One app at a time: an empty message says it's in use
                    static const uint8_t in_use[2] = { 0, 0 };
                    if (send(c, in_use, sizeof(in_use), MSG_NOSIGNAL) < 0)
                    {
                        // it's gone already
                    }
                    close(c);
                }
                else
                {
                    pthread_mutex_lock(&lock);
                    out_len = 0;
                    partial_len = 0;
                    in_count = 0;
                    client_fd = c;
                    pthread_mutex_unlock(&lock);
                    mark_in_use(true);
                    printf("App connected\n");
                }
            }
        }
        if (fd >= 0 && fd == client_fd)
        {
            if (fds[2].revents & (POLLERR | POLLNVAL))
            {
                drop_client(NULL);
            }
            else if ((fds[2].revents & (POLLIN | POLLHUP)) && !read_client(fd))
            {
                drop_client(NULL);
            }
            else if ((fds[2].revents & POLLOUT) && !write_client(fd))
            {
                drop_client(NULL);
            }
        }
    }
    return NULL;
}

void rcat_hal_ble_peer_setup(const rcat_hal_ble_peer_service_t *service)
{
    // There's only the one service: the app knows the socket by its name.
}

bool rcat_hal_ble_peer_start(const char *name)
{
    if (!thread_started)
    {
        if (!socket_path(path, sizeof(path)))
        {
            return false;
        }
        snprintf(inuse_path, sizeof(inuse_path), "%s.inuse", path);
        wake_fd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
        if (wake_fd < 0 || pthread_create(&thread, NULL, peer_thread, NULL) != 0)
        {
            return false;
        }
        pthread_setname_np(thread, "peer");
        thread_started = true;
    }
    wanted = true;
    wake();
    return true;
}

void rcat_hal_ble_peer_stop(void)
{
    wanted = false;
    wake();
}

void host_peer_close(void)
{
    wanted = false;
    int fd = client_fd;
    if (fd >= 0)
    {
        shutdown(fd, SHUT_RDWR);
    }
    if (path[0] != '\0')
    {
        unlink(path);
        unlink(inuse_path);
    }
}

bool rcat_hal_ble_peer_connected(void)
{
    return client_fd >= 0;
}

int32_t rcat_hal_ble_peer_passkey(void)
{
    return -1;
}

int rcat_hal_ble_peer_paired(const rcat_hal_ble_device_t *keep)
{
    return 0;
}

void rcat_hal_ble_peer_forget_all(const rcat_hal_ble_device_t *keep)
{
    // Nothing's paired: just drop the app, as a board drops the phone
    int fd = client_fd;
    if (fd >= 0)
    {
        shutdown(fd, SHUT_RDWR);
        wake();
    }
}

void rcat_hal_ble_peer_allow_pairing(bool allow)
{
}

size_t rcat_hal_ble_peer_max_send(void)
{
    return rcat_hal_ble_peer_connected() ? RCAT_HAL_BLE_PEER_MSG_MAX : 0;
}

bool rcat_hal_ble_peer_send(const void *data, size_t len)
{
    if (len == 0 || len > RCAT_HAL_BLE_PEER_MSG_MAX)
    {
        return false;
    }
    pthread_mutex_lock(&lock);
    bool ok = client_fd >= 0 && out_len + 2 + len <= sizeof(out_buf);
    if (ok)
    {
        out_buf[out_len++] = (uint8_t)len;
        out_buf[out_len++] = (uint8_t)(len >> 8);
        memcpy(out_buf + out_len, data, len);
        out_len += len;
    }
    pthread_mutex_unlock(&lock);
    if (ok)
    {
        wake();
    }
    return ok;
}

size_t rcat_hal_ble_peer_receive(void *data, size_t max)
{
    size_t len = 0;
    pthread_mutex_lock(&lock);
    if (in_count > 0)
    {
        len = in_len[in_head] < max ? in_len[in_head] : max;
        memcpy(data, in_msgs[in_head], len);
        in_head = (in_head + 1) % RCAT_HAL_BLE_PEER_MSGS;
        in_count--;
    }
    pthread_mutex_unlock(&lock);
    return len;
}

void rcat_hal_ble_peer_fast(bool fast)
{
}
