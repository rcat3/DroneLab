/*
 * Bluetooth LE for the HAL (see "Bluetooth LE" in hal.h), on ESP-IDF's
 * NimBLE stack as a central with a few links, as a peripheral that one
 * phone connects to (on boards configured with the peripheral role), and as
 * the host of one paired button, a HID remote (on boards with pairing).
 *
 * One scan serves everything that needs one: finding devices for the links,
 * finding a button to pair, and watching for the paired button to wake up.
 *
 * NimBLE runs on its own task and calls back from there. The UI loop only
 * reads the state and buffers kept here, under ble_lock, and starts NimBLE
 * procedures, which NimBLE allows from any task.
 */

#include <stdio.h>
#include <string.h>

#include "freertos/FreeRTOS.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "host/ble_hs.h"
#include "host/util/util.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#if CONFIG_BT_NIMBLE_ROLE_PERIPHERAL
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"
#endif
#if CONFIG_BT_NIMBLE_SECURITY_ENABLE
#include "host/ble_store.h"
void ble_store_config_init(void);   // NimBLE's bonds, kept in NVS
#endif

#include "hal.h"

static const char *TAG = "ble";

#define BLE_MAX_DEVICES         16
#define BLE_RX_BUFFER           256
#define BLE_CONNECT_TIMEOUT_MS  8000
// The controller takes about 38 KB of internal RAM when it starts, and
// crashes rather than failing if it can't get it.
#define BLE_MIN_FREE_INTERNAL   (40 * 1024)

typedef struct
{
    // Shared with the UI loop, under ble_lock
    rcat_hal_ble_state_t state;
    uint8_t rx_buffer[BLE_RX_BUFFER];
    size_t rx_head;             // where the next byte goes
    size_t rx_count;

    // Set up before connecting, then only touched on the NimBLE task
    uint16_t conn_handle;
    char name[32];
    rcat_hal_ble_service_match_t service_match;
    uint16_t svc_start, svc_end;
    uint16_t tx_handle, rx_handle, rx_end, cccd_handle;
    bool tx_no_rsp;
} ble_link_t;

static portMUX_TYPE ble_lock = portMUX_INITIALIZER_UNLOCKED;

// Shared with the UI loop, under ble_lock
static ble_link_t links[RCAT_HAL_BLE_MAX_LINKS];
static rcat_hal_ble_device_t found[BLE_MAX_DEVICES];
static size_t found_count;

static bool started;
static volatile bool synced;
static volatile bool scan_wanted;
static uint8_t own_addr_type;

static int scan_event_cb(struct ble_gap_event *event, void *arg);
static int link_event_cb(struct ble_gap_event *event, void *arg);
static void peer_register(void);
static void peer_advertise(void);
static bool button_finding(void);
static bool button_watching(void);
static void button_seen(const struct ble_gap_disc_desc *disc);

static void set_state(ble_link_t *link, rcat_hal_ble_state_t s)
{
    taskENTER_CRITICAL(&ble_lock);
    link->state = s;
    taskEXIT_CRITICAL(&ble_lock);
}

rcat_hal_ble_state_t rcat_hal_ble_link_state(int link)
{
    if (link < 0 || link >= RCAT_HAL_BLE_MAX_LINKS)
    {
        return RCAT_HAL_BLE_IDLE;
    }
    taskENTER_CRITICAL(&ble_lock);
    rcat_hal_ble_state_t s = links[link].state;
    taskEXIT_CRITICAL(&ble_lock);
    return s;
}

/********************************************************************************
function:	Scanning: in full while looking for devices, or just now and then
            while only watching for the paired button to wake up
********************************************************************************/
typedef enum
{
    SCAN_NONE,
    SCAN_WATCH,     // passive, 30 ms in every 200: the button advertises every
                    // 20 to 30 ms once a press wakes it, so it's seen in 200 ms
    SCAN_FULL,      // active, all the time, for names in scan responses
} scan_mode_t;

static volatile scan_mode_t scan_mode_now = SCAN_NONE;

static scan_mode_t scan_mode_wanted(void)
{
    if (scan_wanted || button_finding())
    {
        return SCAN_FULL;
    }
    return button_watching() ? SCAN_WATCH : SCAN_NONE;
}

/* Start, stop or change the scan to suit what's wanted. Safe to call from
 * any task. NimBLE can't scan while it's connecting, so a connection restarts
 * it when it's made, or fails. */
static void scan_update(void)
{
    if (!synced)
    {
        return;
    }
    scan_mode_t want = scan_mode_wanted();
    if (ble_gap_disc_active())
    {
        if (want == scan_mode_now)
        {
            return;
        }
        ble_gap_disc_cancel();
    }
    scan_mode_now = SCAN_NONE;
    if (want == SCAN_NONE || ble_gap_conn_active())
    {
        return;
    }
    struct ble_gap_disc_params params = {
        .passive = want == SCAN_WATCH,
        .filter_duplicates = 0,     // the name can come in a later report than the first
    };
    if (want == SCAN_WATCH)
    {
        params.itvl = 320;          // 200 ms, in 0.625 ms steps
        params.window = 48;         // 30 ms
    }
    int rc = ble_gap_disc(own_addr_type, BLE_HS_FOREVER, &params, scan_event_cb, NULL);
    if (rc == 0)
    {
        scan_mode_now = want;
    }
    else if (rc != BLE_HS_EALREADY)
    {
        ESP_LOGE(TAG, "Scan didn't start (%d)", rc);
    }
}

static void add_device(const struct ble_gap_disc_desc *disc)
{
    struct ble_hs_adv_fields fields;
    if (ble_hs_adv_parse_fields(&fields, disc->data, disc->length_data) != 0)
    {
        return;
    }

    taskENTER_CRITICAL(&ble_lock);
    rcat_hal_ble_device_t *d = NULL;
    for (size_t i = 0; i < found_count; i++)
    {
        if (found[i].addr_type == disc->addr.type && memcmp(found[i].addr, disc->addr.val, 6) == 0)
        {
            d = &found[i];
            break;
        }
    }
    if (d == NULL && fields.name != NULL && fields.name_len > 0 && found_count < BLE_MAX_DEVICES)
    {
        d = &found[found_count++];
        memcpy(d->addr, disc->addr.val, 6);
        d->addr_type = disc->addr.type;
    }
    if (d != NULL)
    {
        d->rssi = disc->rssi;
        if (fields.name != NULL && fields.name_len > 0)
        {
            size_t len = fields.name_len < sizeof(d->name) - 1 ? fields.name_len : sizeof(d->name) - 1;
            memcpy(d->name, fields.name, len);
            d->name[len] = '\0';
        }
    }
    taskEXIT_CRITICAL(&ble_lock);
}

static int scan_event_cb(struct ble_gap_event *event, void *arg)
{
    if (event->type == BLE_GAP_EVENT_DISC)
    {
        if (scan_wanted)
        {
            add_device(&event->disc);
        }
        button_seen(&event->disc);
    }
    else if (event->type == BLE_GAP_EVENT_DISC_COMPLETE)
    {
        scan_mode_now = SCAN_NONE;
        scan_update();
    }
    return 0;
}

/********************************************************************************
function:	Finding the link: the service, its two characteristics, and the
			descriptor that turns notifications on
********************************************************************************/
static void link_failed(ble_link_t *link, const char *why, int rc)
{
    ESP_LOGW(TAG, "%s: %s (%d), disconnecting", link->name, why, rc);
    ble_gap_terminate(link->conn_handle, BLE_ERR_REM_USER_CONN_TERM);
}

static void link_ready(ble_link_t *link)
{
    ESP_LOGI(TAG, "%s: link ready (write handle %u, notify handle %u). Free internal RAM: %u bytes",
             link->name, link->tx_handle, link->rx_handle,
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL));
    taskENTER_CRITICAL(&ble_lock);
    link->rx_count = 0;
    link->state = RCAT_HAL_BLE_CONNECTED;
    taskEXIT_CRITICAL(&ble_lock);
}

static int cccd_write_cb(uint16_t conn, const struct ble_gatt_error *error, struct ble_gatt_attr *attr, void *arg)
{
    ble_link_t *link = arg;
    if (error->status != 0)
    {
        link_failed(link, "notifications didn't turn on", error->status);
        return 0;
    }
    link_ready(link);
    return 0;
}

static int dsc_cb(uint16_t conn, const struct ble_gatt_error *error, uint16_t chr_val_handle,
                  const struct ble_gatt_dsc *dsc, void *arg)
{
    ble_link_t *link = arg;
    if (error->status == 0)
    {
        if (ble_uuid_cmp(&dsc->uuid.u, BLE_UUID16_DECLARE(BLE_GATT_DSC_CLT_CFG_UUID16)) == 0)
        {
            link->cccd_handle = dsc->handle;
        }
        return 0;
    }
    if (error->status != BLE_HS_EDONE)
    {
        link_failed(link, "descriptor discovery failed", error->status);
        return 0;
    }

    if (link->cccd_handle == 0)
    {
        ESP_LOGW(TAG, "%s: no notification descriptor, so nothing will be received", link->name);
        link_ready(link);
        return 0;
    }
    static const uint8_t notify_on[2] = { 1, 0 };
    int rc = ble_gattc_write_flat(conn, link->cccd_handle, notify_on, sizeof(notify_on), cccd_write_cb, link);
    if (rc != 0)
    {
        link_failed(link, "couldn't turn notifications on", rc);
    }
    return 0;
}

static int chr_cb(uint16_t conn, const struct ble_gatt_error *error, const struct ble_gatt_chr *chr, void *arg)
{
    ble_link_t *link = arg;
    if (error->status == 0)
    {
        // The characteristic after the notifying one ends its descriptors.
        if (link->rx_handle != 0 && link->rx_end == 0)
        {
            link->rx_end = chr->def_handle - 1;
        }
        if (link->tx_handle == 0 && (chr->properties & (BLE_GATT_CHR_PROP_WRITE | BLE_GATT_CHR_PROP_WRITE_NO_RSP)))
        {
            link->tx_handle = chr->val_handle;
            link->tx_no_rsp = (chr->properties & BLE_GATT_CHR_PROP_WRITE_NO_RSP) != 0;
        }
        if (link->rx_handle == 0 && (chr->properties & BLE_GATT_CHR_PROP_NOTIFY))
        {
            link->rx_handle = chr->val_handle;
        }
        return 0;
    }
    if (error->status != BLE_HS_EDONE)
    {
        link_failed(link, "characteristic discovery failed", error->status);
        return 0;
    }

    if (link->tx_handle == 0)
    {
        link_failed(link, "the service has nothing to write to", 0);
        return 0;
    }
    if (link->rx_handle == 0)
    {
        link_ready(link);
        return 0;
    }
    if (link->rx_end == 0)
    {
        link->rx_end = link->svc_end;
    }
    int rc = ble_gattc_disc_all_dscs(conn, link->rx_handle, link->rx_end, dsc_cb, link);
    if (rc != 0)
    {
        link_failed(link, "descriptor discovery didn't start", rc);
    }
    return 0;
}

static void uuid_to_bytes(const ble_uuid_t *uuid, uint8_t out[16])
{
    // The Bluetooth base UUID, 00000000-0000-1000-8000-00805f9b34fb
    static const uint8_t base[16] = { 0, 0, 0, 0, 0x00, 0x00, 0x10, 0x00,
                                      0x80, 0x00, 0x00, 0x80, 0x5f, 0x9b, 0x34, 0xfb };
    memcpy(out, base, 16);
    switch (uuid->type)
    {
    case BLE_UUID_TYPE_16:
    {
        uint16_t v = BLE_UUID16(uuid)->value;
        out[2] = v >> 8;
        out[3] = v & 0xFF;
        break;
    }
    case BLE_UUID_TYPE_32:
    {
        uint32_t v = BLE_UUID32(uuid)->value;
        out[0] = v >> 24;
        out[1] = (v >> 16) & 0xFF;
        out[2] = (v >> 8) & 0xFF;
        out[3] = v & 0xFF;
        break;
    }
    default:
        // NimBLE keeps 128-bit UUIDs least significant byte first.
        for (int i = 0; i < 16; i++)
        {
            out[i] = BLE_UUID128(uuid)->value[15 - i];
        }
        break;
    }
}

static int svc_cb(uint16_t conn, const struct ble_gatt_error *error, const struct ble_gatt_svc *service, void *arg)
{
    ble_link_t *link = arg;
    if (error->status == 0)
    {
        uint8_t uuid[16];
        uuid_to_bytes(&service->uuid.u, uuid);
        if (link->svc_start == 0 && link->service_match(uuid))
        {
            link->svc_start = service->start_handle;
            link->svc_end = service->end_handle;
        }
        return 0;
    }
    if (error->status != BLE_HS_EDONE)
    {
        link_failed(link, "service discovery failed", error->status);
        return 0;
    }

    if (link->svc_start == 0)
    {
        link_failed(link, "no matching service", 0);
        return 0;
    }
    int rc = ble_gattc_disc_all_chrs(conn, link->svc_start, link->svc_end, chr_cb, link);
    if (rc != 0)
    {
        link_failed(link, "characteristic discovery didn't start", rc);
    }
    return 0;
}

/********************************************************************************
function:	A link's events, on NimBLE's task
********************************************************************************/
static int link_event_cb(struct ble_gap_event *event, void *arg)
{
    ble_link_t *link = arg;
    switch (event->type)
    {
    case BLE_GAP_EVENT_CONNECT:
        if (event->connect.status != 0)
        {
            ESP_LOGW(TAG, "%s: connection failed (%d)", link->name, event->connect.status);
            set_state(link, RCAT_HAL_BLE_IDLE);
            scan_update();
            break;
        }
        else
        {
            link->conn_handle = event->connect.conn_handle;
            ESP_LOGI(TAG, "%s: connected, finding the link", link->name);
            int rc = ble_gattc_disc_all_svcs(link->conn_handle, svc_cb, link);
            if (rc != 0)
            {
                link_failed(link, "service discovery didn't start", rc);
            }
        }
        scan_update();  // carry on scanning, if it was
        break;

    case BLE_GAP_EVENT_DISCONNECT:
        ESP_LOGI(TAG, "%s: disconnected (reason %d)", link->name, event->disconnect.reason);
        link->conn_handle = BLE_HS_CONN_HANDLE_NONE;
        set_state(link, RCAT_HAL_BLE_IDLE);
        break;

    case BLE_GAP_EVENT_NOTIFY_RX:
        if (event->notify_rx.attr_handle == link->rx_handle)
        {
            struct os_mbuf *om = event->notify_rx.om;
            uint8_t data[64];
            uint16_t len = OS_MBUF_PKTLEN(om);
            if (len > sizeof(data))
            {
                len = sizeof(data);
            }
            os_mbuf_copydata(om, 0, len, data);
            taskENTER_CRITICAL(&ble_lock);
            for (uint16_t i = 0; i < len; i++)
            {
                link->rx_buffer[link->rx_head] = data[i];
                link->rx_head = (link->rx_head + 1) % BLE_RX_BUFFER;
                if (link->rx_count < BLE_RX_BUFFER)
                {
                    link->rx_count++;   // otherwise the oldest byte has been overwritten
                }
            }
            taskEXIT_CRITICAL(&ble_lock);
        }
        break;

    default:
        break;
    }
    return 0;
}

static void on_sync(void)
{
    ble_hs_util_ensure_addr(0);
    ble_hs_id_infer_auto(0, &own_addr_type);
    synced = true;
    ESP_LOGI(TAG, "Bluetooth ready");
    scan_update();
    peer_advertise();
}

static void on_reset(int reason)
{
    ESP_LOGW(TAG, "Bluetooth reset (%d)", reason);
    synced = false;
}

static void host_task(void *param)
{
    nimble_port_run();
    nimble_port_freertos_deinit();
}

/* Start the stack the first time it's needed. */
static bool ble_start(void)
{
    if (started)
    {
        return true;
    }
    size_t free_internal = heap_caps_get_free_size(MALLOC_CAP_INTERNAL);
    ESP_LOGI(TAG, "Free internal RAM before Bluetooth: %u bytes", (unsigned)free_internal);
    if (free_internal < BLE_MIN_FREE_INTERNAL)
    {
        ESP_LOGE(TAG, "Not enough internal RAM for Bluetooth (it needs about %u bytes)",
                 (unsigned)BLE_MIN_FREE_INTERNAL);
        return false;
    }
    esp_err_t err = nimble_port_init();
    // NimBLE logs every notification at info level, which buries everything
    // else while the comm channel sends 50 a second.
    esp_log_level_set("NimBLE", ESP_LOG_WARN);
    if (err != ESP_OK)
    {
        ESP_LOGE(TAG, "Bluetooth didn't start (%s)", esp_err_to_name(err));
        return false;
    }
    for (int i = 0; i < RCAT_HAL_BLE_MAX_LINKS; i++)
    {
        links[i].conn_handle = BLE_HS_CONN_HANDLE_NONE;
    }
    ble_hs_cfg.sync_cb = on_sync;
    ble_hs_cfg.reset_cb = on_reset;
#if CONFIG_BT_NIMBLE_SECURITY_ENABLE
    // Pairing, remembered (bonded) so it isn't needed again. The board can
    // show a code, which a phone types in: its link is then safe from anyone
    // listening in or pretending. The button has no screen or keys, so it
    // pairs without a code ("just works").
    ble_hs_cfg.sm_io_cap = BLE_SM_IO_CAP_DISP_ONLY;
    ble_hs_cfg.sm_bonding = 1;
    ble_hs_cfg.sm_mitm = 1;
    ble_hs_cfg.sm_sc = 1;
    ble_hs_cfg.sm_our_key_dist = BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID;
    ble_hs_cfg.sm_their_key_dist = BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID;
    ble_hs_cfg.store_status_cb = ble_store_util_status_rr;
    ble_store_config_init();
#endif
    peer_register();    // services have to be in place before the host starts
    nimble_port_freertos_init(host_task);
    started = true;
    ESP_LOGI(TAG, "Free internal RAM after Bluetooth: %u bytes",
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL));
    return true;
}

/********************************************************************************
function:	The HAL functions, called from the UI loop
********************************************************************************/
bool rcat_hal_ble_scan_start(void)
{
    if (!ble_start())
    {
        return false;
    }
    taskENTER_CRITICAL(&ble_lock);
    found_count = 0;
    taskEXIT_CRITICAL(&ble_lock);

    scan_wanted = true;
    scan_update();      // or on_sync does, once the stack is ready
    return true;
}

void rcat_hal_ble_scan_stop(void)
{
    scan_wanted = false;
    if (started)
    {
        scan_update();  // stops it, unless the button still needs it
    }
}

size_t rcat_hal_ble_scan_results(rcat_hal_ble_device_t *devices, size_t max)
{
    taskENTER_CRITICAL(&ble_lock);
    size_t n = found_count < max ? found_count : max;
    memcpy(devices, found, n * sizeof(found[0]));
    taskEXIT_CRITICAL(&ble_lock);
    return n;
}

int rcat_hal_ble_connect(const rcat_hal_ble_device_t *device, rcat_hal_ble_service_match_t match)
{
    if (!started || !synced || match == NULL || ble_gap_conn_active())
    {
        return -1;
    }
    int free_link = -1;
    for (int i = 0; i < RCAT_HAL_BLE_MAX_LINKS; i++)
    {
        rcat_hal_ble_state_t s = rcat_hal_ble_link_state(i);
        if (s == RCAT_HAL_BLE_CONNECTING)
        {
            return -1;      // one at a time
        }
        if (s == RCAT_HAL_BLE_IDLE && links[i].conn_handle == BLE_HS_CONN_HANDLE_NONE && free_link < 0)
        {
            free_link = i;
        }
    }
    if (free_link < 0)
    {
        return -1;
    }

    // NimBLE can't scan and connect at once. The scan picks up again once
    // the connection is made, or fails.
    if (ble_gap_disc_active())
    {
        ble_gap_disc_cancel();
        scan_mode_now = SCAN_NONE;
    }

    ble_link_t *link = &links[free_link];
    link->service_match = match;
    link->svc_start = link->svc_end = 0;
    link->tx_handle = link->rx_handle = link->rx_end = link->cccd_handle = 0;
    memcpy(link->name, device->name, sizeof(link->name));
    link->name[sizeof(link->name) - 1] = '\0';
    set_state(link, RCAT_HAL_BLE_CONNECTING);

    ble_addr_t addr = { .type = device->addr_type };
    memcpy(addr.val, device->addr, 6);
    int rc = ble_gap_connect(own_addr_type, &addr, BLE_CONNECT_TIMEOUT_MS, NULL, link_event_cb, link);
    if (rc != 0)
    {
        ESP_LOGE(TAG, "Couldn't connect to %s (%d)", device->name, rc);
        set_state(link, RCAT_HAL_BLE_IDLE);
        scan_update();
        return -1;
    }
    ESP_LOGI(TAG, "Connecting to %s on link %d", device->name, free_link);
    return free_link;
}

void rcat_hal_ble_disconnect(int link)
{
    if (!started || link < 0 || link >= RCAT_HAL_BLE_MAX_LINKS)
    {
        return;
    }
    ble_link_t *l = &links[link];
    if (l->conn_handle != BLE_HS_CONN_HANDLE_NONE)
    {
        ble_gap_terminate(l->conn_handle, BLE_ERR_REM_USER_CONN_TERM);
    }
    else if (rcat_hal_ble_link_state(link) == RCAT_HAL_BLE_CONNECTING && ble_gap_conn_active())
    {
        ble_gap_conn_cancel();      // reported as a failed connection, which goes back to idle
    }
}

bool rcat_hal_ble_send(int link, const void *data, size_t len)
{
    if (rcat_hal_ble_link_state(link) != RCAT_HAL_BLE_CONNECTED)
    {
        return false;
    }
    ble_link_t *l = &links[link];
    int rc = l->tx_no_rsp ? ble_gattc_write_no_rsp_flat(l->conn_handle, l->tx_handle, data, len)
                          : ble_gattc_write_flat(l->conn_handle, l->tx_handle, data, len, NULL, NULL);
    return rc == 0;
}

size_t rcat_hal_ble_receive(int link, void *data, size_t max)
{
    if (link < 0 || link >= RCAT_HAL_BLE_MAX_LINKS)
    {
        return 0;
    }
    ble_link_t *l = &links[link];
    uint8_t *out = data;
    taskENTER_CRITICAL(&ble_lock);
    size_t n = l->rx_count < max ? l->rx_count : max;
    size_t tail = (l->rx_head + BLE_RX_BUFFER - l->rx_count) % BLE_RX_BUFFER;
    for (size_t i = 0; i < n; i++)
    {
        out[i] = l->rx_buffer[(tail + i) % BLE_RX_BUFFER];
    }
    l->rx_count -= n;
    taskEXIT_CRITICAL(&ble_lock);
    return n;
}

/********************************************************************************
function:	The button: a Bluetooth LE HID remote, like a camera shutter
            remote, paired with the board. It's a keyboard to the board: each
            of its input reports notifies when a key goes down and again,
            all zeros, when it comes up.

            Once paired, the board keeps the bond, and whenever the button's
            wanted and not connected, it watches for the button's advertising.
            Such buttons sleep after a minute or so, and a press wakes them;
            the board connects, the bond's encryption comes back without
            pairing again, and the button sends the press that woke it.
            The report handles are kept from the first connection, and
            notifications stay on for a bonded host, so a reconnection is
            quick.
********************************************************************************/
#if CONFIG_BT_NIMBLE_SECURITY_ENABLE

#define BUTTON_MAX_FOUND    8
#define BUTTON_MAX_REPORTS  8
#define BUTTON_HID_SERVICE  0x1812
#define BUTTON_HID_REPORT   0x2A4D

static struct
{
    // Set from the UI loop, while the button isn't wanted
    ble_addr_t addr;
    char name[32];
    volatile bool wanted;
    volatile bool finding;

    // On the NimBLE task, read by the UI loop
    volatile rcat_hal_ble_button_state_t state;
    volatile uint16_t conn;
    volatile uint32_t held;     // a bit for each report with a key down

    // Only on the NimBLE task
    bool known;                 // the handles below are this button's
    uint16_t svc_start, svc_end;
    uint8_t reports;
    uint16_t report_val[BUTTON_MAX_REPORTS];
    uint16_t report_end[BUTTON_MAX_REPORTS];
    uint16_t report_cccd[BUTTON_MAX_REPORTS];
    uint8_t step;
} button = { .conn = BLE_HS_CONN_HANDLE_NONE };

// Buttons found while finding, under ble_lock
static rcat_hal_ble_device_t button_found[BUTTON_MAX_FOUND];
static size_t button_found_count;

static int button_event_cb(struct ble_gap_event *event, void *arg);
static void button_subscribe(void);

static bool button_finding(void)
{
    return button.finding;
}

static bool button_watching(void)
{
    return button.wanted && button.conn == BLE_HS_CONN_HANDLE_NONE &&
           button.state != RCAT_HAL_BLE_BUTTON_CONNECTING;
}

static void button_set_state(rcat_hal_ble_button_state_t s)
{
    button.state = s;
}

/* Does this advertisement come from a HID device: the HID service, or a HID
 * appearance (0x03C0 to 0x03FF)? */
static bool is_hid(const struct ble_hs_adv_fields *f)
{
    for (int i = 0; i < f->num_uuids16; i++)
    {
        if (ble_uuid_u16(&f->uuids16[i].u) == BUTTON_HID_SERVICE)
        {
            return true;
        }
    }
    return f->appearance_is_present && (f->appearance >> 6) == (0x03C0 >> 6);
}

static void button_connect(void)
{
    if (ble_gap_conn_active() || !button.wanted)
    {
        return;     // another connection's in progress: the next advertisement tries again
    }
    if (ble_gap_disc_active())
    {
        ble_gap_disc_cancel();
        scan_mode_now = SCAN_NONE;
    }
    button_set_state(RCAT_HAL_BLE_BUTTON_CONNECTING);
    int rc = ble_gap_connect(own_addr_type, &button.addr, BLE_CONNECT_TIMEOUT_MS, NULL, button_event_cb, NULL);
    if (rc != 0)
    {
        ESP_LOGW(TAG, "Button: couldn't connect (%d)", rc);
        button_set_state(RCAT_HAL_BLE_BUTTON_WAITING);
        scan_update();
    }
}

/* Every advertisement the scan sees, on the NimBLE task. */
static void button_seen(const struct ble_gap_disc_desc *disc)
{
    if (button_watching() && disc->addr.type == button.addr.type &&
        memcmp(disc->addr.val, button.addr.val, 6) == 0)
    {
        ESP_LOGI(TAG, "Button: awake, connecting");
        button_connect();
        return;
    }
    if (!button.finding)
    {
        return;
    }
    struct ble_hs_adv_fields fields;
    if (ble_hs_adv_parse_fields(&fields, disc->data, disc->length_data) != 0)
    {
        return;
    }
    taskENTER_CRITICAL(&ble_lock);
    rcat_hal_ble_device_t *d = NULL;
    for (size_t i = 0; i < button_found_count; i++)
    {
        if (button_found[i].addr_type == disc->addr.type && memcmp(button_found[i].addr, disc->addr.val, 6) == 0)
        {
            d = &button_found[i];
            break;
        }
    }
    // The first advertisement says it's a HID device; a scan response may
    // only bring its name.
    if (d == NULL && is_hid(&fields) && button_found_count < BUTTON_MAX_FOUND)
    {
        d = &button_found[button_found_count++];
        memset(d, 0, sizeof(*d));
        memcpy(d->addr, disc->addr.val, 6);
        d->addr_type = disc->addr.type;
        strcpy(d->name, "Button");
    }
    if (d != NULL)
    {
        d->rssi = disc->rssi;
        if (fields.name != NULL && fields.name_len > 0)
        {
            size_t len = fields.name_len < sizeof(d->name) - 1 ? fields.name_len : sizeof(d->name) - 1;
            memcpy(d->name, fields.name, len);
            d->name[len] = '\0';
        }
    }
    taskEXIT_CRITICAL(&ble_lock);
}

static void button_failed(const char *why, int rc)
{
    ESP_LOGW(TAG, "Button: %s (%d), disconnecting", why, rc);
    ble_gap_terminate(button.conn, BLE_ERR_REM_USER_CONN_TERM);
}

static void button_ready(void)
{
    button.known = true;
    button_set_state(RCAT_HAL_BLE_BUTTON_CONNECTED);
    ESP_LOGI(TAG, "Button: ready, %u key report%s", button.reports, button.reports == 1 ? "" : "s");
}

/* Turn notifications on for each report in turn (step), then it's ready. */
static int button_cccd_cb(uint16_t conn, const struct ble_gatt_error *error, struct ble_gatt_attr *attr, void *arg)
{
    if (error->status != 0)
    {
        button_failed("a report's notifications didn't turn on", error->status);
        return 0;
    }
    button.step++;
    button_subscribe();
    return 0;
}

static void button_subscribe(void)
{
    while (button.step < button.reports && button.report_cccd[button.step] == 0)
    {
        button.step++;      // a report that can't notify
    }
    if (button.step >= button.reports)
    {
        button_ready();
        return;
    }
    static const uint8_t notify_on[2] = { 1, 0 };
    int rc = ble_gattc_write_flat(button.conn, button.report_cccd[button.step], notify_on, sizeof(notify_on),
                                  button_cccd_cb, NULL);
    if (rc != 0)
    {
        button_failed("couldn't turn notifications on", rc);
    }
}

/* Find each report's notification descriptor in turn (step). */
static int button_dsc_cb(uint16_t conn, const struct ble_gatt_error *error, uint16_t chr_val_handle,
                         const struct ble_gatt_dsc *dsc, void *arg);

static void button_find_descriptors(void)
{
    if (button.step >= button.reports)
    {
        button.step = 0;
        button_subscribe();
        return;
    }
    uint16_t start = button.report_val[button.step];
    uint16_t end = button.report_end[button.step];
    if (end <= start)
    {
        button.step++;      // no room for descriptors
        button_find_descriptors();
        return;
    }
    int rc = ble_gattc_disc_all_dscs(button.conn, start, end, button_dsc_cb, NULL);
    if (rc != 0)
    {
        button_failed("descriptor discovery didn't start", rc);
    }
}

static int button_dsc_cb(uint16_t conn, const struct ble_gatt_error *error, uint16_t chr_val_handle,
                         const struct ble_gatt_dsc *dsc, void *arg)
{
    if (error->status == 0)
    {
        if (ble_uuid_cmp(&dsc->uuid.u, BLE_UUID16_DECLARE(BLE_GATT_DSC_CLT_CFG_UUID16)) == 0)
        {
            button.report_cccd[button.step] = dsc->handle;
        }
        return 0;
    }
    if (error->status != BLE_HS_EDONE)
    {
        button_failed("descriptor discovery failed", error->status);
        return 0;
    }
    button.step++;
    button_find_descriptors();
    return 0;
}

static int button_chr_cb(uint16_t conn, const struct ble_gatt_error *error, const struct ble_gatt_chr *chr, void *arg)
{
    if (error->status == 0)
    {
        // The next characteristic ends the last report's descriptors
        if (button.reports > 0 && button.report_end[button.reports - 1] == 0)
        {
            button.report_end[button.reports - 1] = chr->def_handle - 1;
        }
        if (ble_uuid_cmp(&chr->uuid.u, BLE_UUID16_DECLARE(BUTTON_HID_REPORT)) == 0 &&
            (chr->properties & BLE_GATT_CHR_PROP_NOTIFY) && button.reports < BUTTON_MAX_REPORTS)
        {
            int i = button.reports++;
            button.report_val[i] = chr->val_handle;
            button.report_end[i] = 0;
            button.report_cccd[i] = 0;
        }
        return 0;
    }
    if (error->status != BLE_HS_EDONE)
    {
        button_failed("characteristic discovery failed", error->status);
        return 0;
    }
    if (button.reports == 0)
    {
        button_failed("it has no key reports", 0);
        return 0;
    }
    if (button.report_end[button.reports - 1] == 0)
    {
        button.report_end[button.reports - 1] = button.svc_end;
    }
    button.step = 0;
    button_find_descriptors();
    return 0;
}

static int button_svc_cb(uint16_t conn, const struct ble_gatt_error *error, const struct ble_gatt_svc *service,
                         void *arg)
{
    if (error->status == 0)
    {
        if (button.svc_start == 0)
        {
            button.svc_start = service->start_handle;
            button.svc_end = service->end_handle;
        }
        return 0;
    }
    if (error->status != BLE_HS_EDONE)
    {
        button_failed("service discovery failed", error->status);
        return 0;
    }
    if (button.svc_start == 0)
    {
        button_failed("it isn't a HID device", 0);
        return 0;
    }
    int rc = ble_gattc_disc_all_chrs(conn, button.svc_start, button.svc_end, button_chr_cb, NULL);
    if (rc != 0)
    {
        button_failed("characteristic discovery didn't start", rc);
    }
    return 0;
}

/* Encrypted: find the reports, or, knowing them, just make sure they notify. */
static void button_encrypted(void)
{
    if (button.known)
    {
        button.step = 0;
        button_subscribe();
        return;
    }
    button.svc_start = button.svc_end = 0;
    button.reports = 0;
    int rc = ble_gattc_disc_svc_by_uuid(button.conn, BLE_UUID16_DECLARE(BUTTON_HID_SERVICE), button_svc_cb, NULL);
    if (rc != 0)
    {
        button_failed("service discovery didn't start", rc);
    }
}

static int button_event_cb(struct ble_gap_event *event, void *arg)
{
    switch (event->type)
    {
    case BLE_GAP_EVENT_CONNECT:
        if (event->connect.status != 0)
        {
            ESP_LOGW(TAG, "Button: connection failed (%d)", event->connect.status);
            button_set_state(button.wanted ? RCAT_HAL_BLE_BUTTON_WAITING : RCAT_HAL_BLE_BUTTON_OFF);
            scan_update();
            break;
        }
        button.conn = event->connect.conn_handle;
        if (!button.wanted)
        {
            ble_gap_terminate(button.conn, BLE_ERR_REM_USER_CONN_TERM);
            break;
        }
        // Encryption comes first: the bond's, or pairing if there's none.
        ESP_LOGI(TAG, "Button: connected, securing the link");
        {
            int rc = ble_gap_security_initiate(button.conn);
            if (rc != 0)
            {
                button_failed("couldn't secure the link", rc);
            }
        }
        scan_update();
        break;

    case BLE_GAP_EVENT_ENC_CHANGE:
        if (event->enc_change.status == 0)
        {
            ESP_LOGI(TAG, "Button: link secured");
            button_encrypted();
        }
        else
        {
            // Most likely the button forgot the board, or paired with
            // something else since: forget its old keys, so the next time
            // it's in pairing mode it pairs afresh.
            ESP_LOGW(TAG, "Button: securing the link failed (%d), forgetting its keys",
                     event->enc_change.status);
            struct ble_gap_conn_desc desc;
            if (ble_gap_conn_find(event->enc_change.conn_handle, &desc) == 0)
            {
                ble_store_util_delete_peer(&desc.peer_id_addr);
            }
            button.known = false;
            ble_gap_terminate(event->enc_change.conn_handle, BLE_ERR_REM_USER_CONN_TERM);
        }
        break;

    case BLE_GAP_EVENT_REPEAT_PAIRING:
    {
        // It's pairing again with keys the board already has: drop the old ones.
        struct ble_gap_conn_desc desc;
        if (ble_gap_conn_find(event->repeat_pairing.conn_handle, &desc) == 0)
        {
            ble_store_util_delete_peer(&desc.peer_id_addr);
        }
        button.known = false;
        return BLE_GAP_REPEAT_PAIRING_RETRY;
    }

    case BLE_GAP_EVENT_NOTIFY_RX:
        for (int i = 0; i < button.reports; i++)
        {
            if (event->notify_rx.attr_handle == button.report_val[i])
            {
                struct os_mbuf *om = event->notify_rx.om;
                uint8_t data[16];
                uint16_t len = OS_MBUF_PKTLEN(om);
                if (len > sizeof(data))
                {
                    len = sizeof(data);
                }
                os_mbuf_copydata(om, 0, len, data);
                bool down = false;
                for (int k = 0; k < len; k++)
                {
                    down |= data[k] != 0;
                }
                uint32_t held = button.held;
                button.held = down ? held | (1u << i) : held & ~(1u << i);
                break;
            }
        }
        break;

    case BLE_GAP_EVENT_DISCONNECT:
        ESP_LOGI(TAG, "Button: disconnected (reason %d)", event->disconnect.reason);
        button.conn = BLE_HS_CONN_HANDLE_NONE;
        button.held = 0;
        button_set_state(button.wanted ? RCAT_HAL_BLE_BUTTON_WAITING : RCAT_HAL_BLE_BUTTON_OFF);
        scan_update();
        break;

    default:
        break;
    }
    return 0;
}

bool rcat_hal_ble_button_find(void)
{
    if (!ble_start())
    {
        return false;
    }
    taskENTER_CRITICAL(&ble_lock);
    button_found_count = 0;
    taskEXIT_CRITICAL(&ble_lock);
    button.finding = true;
    scan_update();
    return true;
}

void rcat_hal_ble_button_find_stop(void)
{
    button.finding = false;
    if (started)
    {
        scan_update();
    }
}

size_t rcat_hal_ble_button_found(rcat_hal_ble_device_t *devices, size_t max)
{
    taskENTER_CRITICAL(&ble_lock);
    size_t n = button_found_count < max ? button_found_count : max;
    memcpy(devices, button_found, n * sizeof(button_found[0]));
    taskEXIT_CRITICAL(&ble_lock);
    return n;
}

bool rcat_hal_ble_button_use(const rcat_hal_ble_device_t *device, bool connect_now)
{
    if (!ble_start())
    {
        return false;
    }
    bool same = button.addr.type == device->addr_type && memcmp(button.addr.val, device->addr, 6) == 0;
    if (button.wanted && same)
    {
        return true;
    }
    rcat_hal_ble_button_stop();
    if (!same)
    {
        button.known = false;
    }
    button.addr.type = device->addr_type;
    memcpy(button.addr.val, device->addr, 6);
    snprintf(button.name, sizeof(button.name), "%s", device->name);
    button_set_state(RCAT_HAL_BLE_BUTTON_WAITING);
    button.wanted = true;
    if (connect_now && synced)
    {
        button_connect();   // it's advertising right now
    }
    else
    {
        scan_update();      // watch for it
    }
    return true;
}

void rcat_hal_ble_button_stop(void)
{
    button.wanted = false;
    button.held = 0;
    if (!started)
    {
        return;
    }
    uint16_t conn = button.conn;
    if (conn != BLE_HS_CONN_HANDLE_NONE)
    {
        ble_gap_terminate(conn, BLE_ERR_REM_USER_CONN_TERM);
    }
    else if (button.state == RCAT_HAL_BLE_BUTTON_CONNECTING && ble_gap_conn_active())
    {
        ble_gap_conn_cancel();
    }
    else
    {
        button_set_state(RCAT_HAL_BLE_BUTTON_OFF);
    }
    scan_update();
}

void rcat_hal_ble_button_forget(const rcat_hal_ble_device_t *device)
{
    if (!ble_start())
    {
        return;
    }
    if (button.addr.type == device->addr_type && memcmp(button.addr.val, device->addr, 6) == 0)
    {
        rcat_hal_ble_button_stop();
        button.known = false;
    }
    ble_addr_t addr = { .type = device->addr_type };
    memcpy(addr.val, device->addr, 6);
    ble_store_util_delete_peer(&addr);
}

rcat_hal_ble_button_state_t rcat_hal_ble_button_state(void)
{
    return button.state;
}

uint32_t rcat_hal_ble_button_held(void)
{
    return button.held;
}

#else   // no pairing on this board, so no button

static bool button_finding(void)
{
    return false;
}

static bool button_watching(void)
{
    return false;
}

static void button_seen(const struct ble_gap_disc_desc *disc)
{
}

bool rcat_hal_ble_button_find(void)
{
    return false;
}

void rcat_hal_ble_button_find_stop(void)
{
}

size_t rcat_hal_ble_button_found(rcat_hal_ble_device_t *devices, size_t max)
{
    return 0;
}

bool rcat_hal_ble_button_use(const rcat_hal_ble_device_t *device, bool connect_now)
{
    return false;
}

void rcat_hal_ble_button_stop(void)
{
}

void rcat_hal_ble_button_forget(const rcat_hal_ble_device_t *device)
{
}

rcat_hal_ble_button_state_t rcat_hal_ble_button_state(void)
{
    return RCAT_HAL_BLE_BUTTON_OFF;
}

uint32_t rcat_hal_ble_button_held(void)
{
    return 0;
}

#endif

/********************************************************************************
function:	The peripheral: one service that a phone connects to
********************************************************************************/
#if CONFIG_BT_NIMBLE_ROLE_PERIPHERAL

// Room for what the phone writes: a few avatars' pieces at once (see
// core/app/comm.h), each as long as the biggest MTU lets it be.
#define PEER_MSGS           32
#define PEER_MSG_MAX        RCAT_HAL_BLE_PEER_MSG_MAX
// How often it advertises, in 0.625 ms steps: 100 to 150 ms, which a phone
// finds in a second or so, without costing much battery.
#define PEER_ADV_MIN        160
#define PEER_ADV_MAX        240
// The connection the board asks for, in 1.25 ms steps: an event every 15 to
// 30 ms, which carries 20 ms sound frames as they come. The board can skip up
// to 4 events when it has nothing to send, to save battery.
#define PEER_CONN_MIN       12
#define PEER_CONN_MAX       24
#define PEER_CONN_LATENCY   4
#define PEER_CONN_TIMEOUT   500     // 10 ms steps

static const rcat_hal_ble_peer_service_t *peer_service;
static ble_uuid128_t peer_svc_uuid, peer_tx_uuid, peer_rx_uuid;
static uint16_t peer_tx_handle;
static char peer_name[32];
static volatile bool peer_wanted;
static volatile uint16_t peer_conn = BLE_HS_CONN_HANDLE_NONE;
static volatile bool peer_subscribed;
static volatile uint16_t peer_mtu;
static volatile bool peer_secure;       // paired with a code: encrypted and authenticated
static volatile int32_t peer_passkey = -1;  // the code to show while pairing
static volatile bool peer_pairing_open;     // a new phone may pair (rcat_hal_ble_peer_allow_pairing)

// What the phone wrote, oldest first, under ble_lock. In PSRAM, as internal
// RAM is short.
static uint8_t (*peer_msgs)[PEER_MSG_MAX];
static uint8_t peer_msg_len[PEER_MSGS];
static size_t peer_msg_head, peer_msg_count;

static int peer_event_cb(struct ble_gap_event *event, void *arg);

static void uuid_from_text_order(const uint8_t in[16], ble_uuid128_t *out)
{
    out->u.type = BLE_UUID_TYPE_128;
    for (int i = 0; i < 16; i++)
    {
        out->value[i] = in[15 - i];     // NimBLE keeps them least significant byte first
    }
}

static int peer_access_cb(uint16_t conn_handle, uint16_t attr_handle, struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    if (ctxt->op != BLE_GATT_ACCESS_OP_WRITE_CHR)
    {
        return 0;       // reading the notify characteristic gives nothing
    }
    uint16_t len = OS_MBUF_PKTLEN(ctxt->om);
    if (len == 0 || len > PEER_MSG_MAX || peer_msgs == NULL)
    {
        return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    }
    uint8_t data[PEER_MSG_MAX];
    os_mbuf_copydata(ctxt->om, 0, len, data);
    taskENTER_CRITICAL(&ble_lock);
    size_t slot = (peer_msg_head + peer_msg_count) % PEER_MSGS;
    if (peer_msg_count == PEER_MSGS)
    {
        peer_msg_head = (peer_msg_head + 1) % PEER_MSGS;   // drop the oldest
    }
    else
    {
        peer_msg_count++;
    }
    memcpy(peer_msgs[slot], data, len);
    peer_msg_len[slot] = len;
    taskEXIT_CRITICAL(&ble_lock);
    return 0;
}

static struct ble_gatt_chr_def peer_chrs[] = {
    {
        .uuid = &peer_tx_uuid.u,
        .access_cb = peer_access_cb,
        .flags = BLE_GATT_CHR_F_NOTIFY,
        .val_handle = &peer_tx_handle,
    },
    {
        .uuid = &peer_rx_uuid.u,
        .access_cb = peer_access_cb,
#if CONFIG_BT_NIMBLE_SECURITY_ENABLE
        // Only from a paired phone: an unpaired one is told to pair
        .flags = BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_NO_RSP | BLE_GATT_CHR_F_WRITE_ENC |
                 BLE_GATT_CHR_F_WRITE_AUTHEN,
#else
        .flags = BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_NO_RSP,
#endif
    },
    { 0 },
};

static const struct ble_gatt_svc_def peer_svcs[] = {
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &peer_svc_uuid.u,
        .characteristics = peer_chrs,
    },
    { 0 },
};

static void peer_register(void)
{
    if (peer_service == NULL)
    {
        return;
    }
    uuid_from_text_order(peer_service->service, &peer_svc_uuid);
    uuid_from_text_order(peer_service->to_phone, &peer_tx_uuid);
    uuid_from_text_order(peer_service->from_phone, &peer_rx_uuid);
    ble_svc_gap_init();
    ble_svc_gatt_init();
    int rc = ble_gatts_count_cfg(peer_svcs);
    if (rc == 0)
    {
        rc = ble_gatts_add_svcs(peer_svcs);
    }
    if (rc != 0)
    {
        ESP_LOGE(TAG, "Couldn't add the phone's service (%d)", rc);
        peer_service = NULL;
    }
}

static void peer_advertise(void)
{
    if (!synced || !peer_wanted || peer_service == NULL || peer_conn != BLE_HS_CONN_HANDLE_NONE
        || ble_gap_adv_active())
    {
        return;
    }
    ble_svc_gap_device_name_set(peer_name);

    // The service in the advertisement, so the phone can look for it, and the
    // name in the scan response, as both don't fit in one.
    struct ble_hs_adv_fields fields = { 0 };
    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    fields.uuids128 = &peer_svc_uuid;
    fields.num_uuids128 = 1;
    fields.uuids128_is_complete = 1;
    int rc = ble_gap_adv_set_fields(&fields);
    if (rc == 0)
    {
        struct ble_hs_adv_fields rsp = { 0 };
        rsp.name = (const uint8_t *)peer_name;
        rsp.name_len = strlen(peer_name);
        rsp.name_is_complete = 1;
        rc = ble_gap_adv_rsp_set_fields(&rsp);
    }
    if (rc == 0)
    {
        struct ble_gap_adv_params params = {
            .conn_mode = BLE_GAP_CONN_MODE_UND,
            .disc_mode = BLE_GAP_DISC_MODE_GEN,
            .itvl_min = PEER_ADV_MIN,
            .itvl_max = PEER_ADV_MAX,
        };
        rc = ble_gap_adv_start(own_addr_type, NULL, BLE_HS_FOREVER, &params, peer_event_cb, NULL);
    }
    if (rc != 0)
    {
        ESP_LOGE(TAG, "Advertising didn't start (%d)", rc);
    }
    else
    {
        ESP_LOGI(TAG, "Advertising as %s", peer_name);
    }
}

static int peer_event_cb(struct ble_gap_event *event, void *arg)
{
    switch (event->type)
    {
    case BLE_GAP_EVENT_CONNECT:
        if (event->connect.status != 0)
        {
            ESP_LOGW(TAG, "Phone's connection failed (%d)", event->connect.status);
            peer_advertise();
            break;
        }
        peer_conn = event->connect.conn_handle;
        peer_mtu = BLE_ATT_MTU_DFLT;
        ESP_LOGI(TAG, "Phone connected");
        if (!peer_wanted)
        {
            ble_gap_terminate(peer_conn, BLE_ERR_REM_USER_CONN_TERM);
            break;
        }
        {
            struct ble_gap_upd_params params = {
                .itvl_min = PEER_CONN_MIN,
                .itvl_max = PEER_CONN_MAX,
                .latency = PEER_CONN_LATENCY,
                .supervision_timeout = PEER_CONN_TIMEOUT,
            };
            ble_gap_update_params(peer_conn, &params);
            ble_gattc_exchange_mtu(peer_conn, NULL, NULL);
#if CONFIG_BT_NIMBLE_SECURITY_ENABLE
            // Ask the phone to pair, or to use its pairing if it has one
            ble_gap_security_initiate(peer_conn);
#else
            peer_secure = true;
#endif
        }
        break;

#if CONFIG_BT_NIMBLE_SECURITY_ENABLE
    case BLE_GAP_EVENT_PASSKEY_ACTION:
        if (!peer_pairing_open)
        {
            // A phone that isn't paired, while pairing's shut: it would show
            // the code on a display that faces the world
            ESP_LOGI(TAG, "Phone pairing refused: pairing's not open");
            ble_gap_terminate(event->passkey.conn_handle, BLE_ERR_AUTH_FAIL);
            break;
        }
        if (event->passkey.params.action == BLE_SM_IOACT_DISP)
        {
            struct ble_sm_io io = { .action = BLE_SM_IOACT_DISP, .passkey = rcat_hal_random() % 1000000 };
            peer_passkey = (int32_t)io.passkey;
            ble_sm_inject_io(event->passkey.conn_handle, &io);
            ESP_LOGI(TAG, "Phone pairing: showing the code");
        }
        break;

    case BLE_GAP_EVENT_ENC_CHANGE:
    {
        struct ble_gap_conn_desc desc;
        bool ok = event->enc_change.status == 0 && ble_gap_conn_find(event->enc_change.conn_handle, &desc) == 0 &&
                  desc.sec_state.encrypted && desc.sec_state.authenticated;
        peer_secure = ok;
        peer_passkey = -1;
        ESP_LOGI(TAG, "Phone's link %s (%d)", ok ? "paired" : "not paired", event->enc_change.status);
        break;
    }

    case BLE_GAP_EVENT_REPEAT_PAIRING:
    {
        // The phone forgot the board and is pairing again: drop the old keys,
        // if pairing's open
        if (!peer_pairing_open)
        {
            return BLE_GAP_REPEAT_PAIRING_IGNORE;
        }
        struct ble_gap_conn_desc desc;
        if (ble_gap_conn_find(event->repeat_pairing.conn_handle, &desc) == 0)
        {
            ble_store_util_delete_peer(&desc.peer_id_addr);
        }
        return BLE_GAP_REPEAT_PAIRING_RETRY;
    }
#endif

    case BLE_GAP_EVENT_DISCONNECT:
        ESP_LOGI(TAG, "Phone disconnected (reason %d)", event->disconnect.reason);
        peer_conn = BLE_HS_CONN_HANDLE_NONE;
        peer_subscribed = false;
        peer_secure = false;
        peer_passkey = -1;
        peer_mtu = 0;
        taskENTER_CRITICAL(&ble_lock);
        peer_msg_count = 0;
        taskEXIT_CRITICAL(&ble_lock);
        peer_advertise();
        break;

    case BLE_GAP_EVENT_ADV_COMPLETE:
        peer_advertise();       // if it stopped for anything but a connection
        break;

    case BLE_GAP_EVENT_SUBSCRIBE:
        if (event->subscribe.attr_handle == peer_tx_handle)
        {
            peer_subscribed = event->subscribe.cur_notify;
            ESP_LOGI(TAG, "Phone turned notifications %s", peer_subscribed ? "on" : "off");
        }
        break;

    case BLE_GAP_EVENT_MTU:
        peer_mtu = event->mtu.value;
        ESP_LOGI(TAG, "Phone's MTU is %u", event->mtu.value);
        break;

    case BLE_GAP_EVENT_CONN_UPDATE:
    {
        struct ble_gap_conn_desc desc;
        if (ble_gap_conn_find(event->conn_update.conn_handle, &desc) == 0)
        {
            ESP_LOGI(TAG, "Phone's connection: an event every %u.%02u ms, latency %u",
                     desc.conn_itvl * 125 / 100, desc.conn_itvl * 125 % 100, desc.conn_latency);
        }
        break;
    }

    default:
        break;
    }
    return 0;
}

void rcat_hal_ble_peer_setup(const rcat_hal_ble_peer_service_t *service)
{
    if (!started)
    {
        peer_service = service;
    }
    if (peer_msgs == NULL)
    {
        peer_msgs = heap_caps_malloc(PEER_MSGS * PEER_MSG_MAX, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
        if (peer_msgs == NULL)
        {
            peer_msgs = malloc(PEER_MSGS * PEER_MSG_MAX);
        }
    }
}

bool rcat_hal_ble_peer_start(const char *name)
{
    // ble_start() can find the service won't go in, and forget it.
    if (peer_service == NULL || !ble_start() || peer_service == NULL)
    {
        return false;
    }
    snprintf(peer_name, sizeof(peer_name), "%s", name);
    peer_wanted = true;
    peer_advertise();       // or on_sync does, once the stack is ready
    return true;
}

void rcat_hal_ble_peer_stop(void)
{
    peer_wanted = false;
    if (!started)
    {
        return;
    }
    if (ble_gap_adv_active())
    {
        ble_gap_adv_stop();
    }
    uint16_t conn = peer_conn;
    if (conn != BLE_HS_CONN_HANDLE_NONE)
    {
        ble_gap_terminate(conn, BLE_ERR_REM_USER_CONN_TERM);
    }
}

bool rcat_hal_ble_peer_connected(void)
{
    return peer_conn != BLE_HS_CONN_HANDLE_NONE && peer_subscribed && peer_secure;
}

int32_t rcat_hal_ble_peer_passkey(void)
{
    return peer_conn != BLE_HS_CONN_HANDLE_NONE ? peer_passkey : -1;
}

#if CONFIG_BT_NIMBLE_SECURITY_ENABLE
#define MAX_PAIRED 16

static bool same_addr(const ble_addr_t *a, const rcat_hal_ble_device_t *d)
{
    return d != NULL && a->type == d->addr_type && memcmp(a->val, d->addr, 6) == 0;
}

int rcat_hal_ble_peer_paired(const rcat_hal_ble_device_t *keep)
{
    if (!started)
    {
        return -1;
    }
    ble_addr_t peers[MAX_PAIRED];
    int count = 0;
    if (ble_store_util_bonded_peers(peers, &count, MAX_PAIRED) != 0)
    {
        return -1;
    }
    int phones = 0;
    for (int i = 0; i < count; i++)
    {
        phones += !same_addr(&peers[i], keep);
    }
    return phones;
}

void rcat_hal_ble_peer_forget_all(const rcat_hal_ble_device_t *keep)
{
    if (!ble_start())
    {
        return;
    }
    ble_addr_t peers[MAX_PAIRED];
    int count = 0;
    if (ble_store_util_bonded_peers(peers, &count, MAX_PAIRED) != 0)
    {
        return;
    }
    int forgot = 0;
    for (int i = 0; i < count; i++)
    {
        if (!same_addr(&peers[i], keep))
        {
            ble_store_util_delete_peer(&peers[i]);
            forgot++;
        }
    }
    // A phone that's connected now has to pair again
    uint16_t conn = peer_conn;
    if (conn != BLE_HS_CONN_HANDLE_NONE)
    {
        ble_gap_terminate(conn, BLE_ERR_REM_USER_CONN_TERM);
    }
    ESP_LOGI(TAG, "Forgot %d paired phone%s", forgot, forgot == 1 ? "" : "s");
}

void rcat_hal_ble_peer_allow_pairing(bool allow)
{
    peer_pairing_open = allow;
}
#else
int rcat_hal_ble_peer_paired(const rcat_hal_ble_device_t *keep)
{
    return -1;
}

void rcat_hal_ble_peer_forget_all(const rcat_hal_ble_device_t *keep)
{
}

void rcat_hal_ble_peer_allow_pairing(bool allow)
{
}
#endif

size_t rcat_hal_ble_peer_max_send(void)
{
    uint16_t mtu = peer_mtu;
    return rcat_hal_ble_peer_connected() && mtu > 3 ? mtu - 3 : 0;
}

bool rcat_hal_ble_peer_send(const void *data, size_t len)
{
    uint16_t conn = peer_conn;
    if (conn == BLE_HS_CONN_HANDLE_NONE || !peer_subscribed || !peer_secure || len == 0 ||
        len > rcat_hal_ble_peer_max_send())
    {
        return false;
    }
    struct os_mbuf *om = ble_hs_mbuf_from_flat(data, len);
    if (om == NULL)
    {
        return false;
    }
    return ble_gatts_notify_custom(conn, peer_tx_handle, om) == 0;     // it frees om either way
}

size_t rcat_hal_ble_peer_receive(void *data, size_t max)
{
    size_t len = 0;
    taskENTER_CRITICAL(&ble_lock);
    if (peer_msg_count > 0)
    {
        len = peer_msg_len[peer_msg_head];
        if (len > max)
        {
            len = max;
        }
        memcpy(data, peer_msgs[peer_msg_head], len);
        peer_msg_head = (peer_msg_head + 1) % PEER_MSGS;
        peer_msg_count--;
    }
    taskEXIT_CRITICAL(&ble_lock);
    return len;
}

#else   // no peripheral role on this board

static void peer_register(void)
{
}

static void peer_advertise(void)
{
}

void rcat_hal_ble_peer_setup(const rcat_hal_ble_peer_service_t *service)
{
}

bool rcat_hal_ble_peer_start(const char *name)
{
    return false;
}

void rcat_hal_ble_peer_stop(void)
{
}

bool rcat_hal_ble_peer_connected(void)
{
    return false;
}

int32_t rcat_hal_ble_peer_passkey(void)
{
    return -1;
}

int rcat_hal_ble_peer_paired(const rcat_hal_ble_device_t *keep)
{
    return -1;
}

void rcat_hal_ble_peer_forget_all(const rcat_hal_ble_device_t *keep)
{
}

void rcat_hal_ble_peer_allow_pairing(bool allow)
{
}

size_t rcat_hal_ble_peer_max_send(void)
{
    return 0;
}

bool rcat_hal_ble_peer_send(const void *data, size_t len)
{
    return false;
}

size_t rcat_hal_ble_peer_receive(void *data, size_t max)
{
    return 0;
}

#endif
