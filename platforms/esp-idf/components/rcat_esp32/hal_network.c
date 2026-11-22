/*
 * WiFi for the HAL, shared by the ESP32 boards: joining a network for the
 * voice lab, the hotspot for the phone remote, and ESP-NOW broadcasts for
 * direct comms. See hal.h.
 *
 * Direct comms can run alongside either of the others: with the hotspot, the
 * radio runs both an access point and a station, on the hotspot's channel,
 * which is also direct comms' own channel when nothing else is running.
 */

#include <stdlib.h>
#include <string.h>

#include "freertos/FreeRTOS.h"

#include "esp_coexist.h"
#include "esp_event.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_now.h"
#include "esp_random.h"
#include "esp_wifi.h"

#include "hal.h"

static const char *TAG = "network";

// WiFi needs about this much internal RAM to start. Below it, starting would
// fail part way, and the driver can't give back what it took (each failed
// try costs about 9 KB), so it isn't tried.
#define WIFI_MIN_FREE_INTERNAL  (40 * 1024)

// Phone remote hotspot
#define HOTSPOT_CHANNEL     6
#define HOTSPOT_MAX_PHONES  4

static bool wifi_ready;
static volatile bool wifi_wanted;
static volatile bool wifi_connected;
static esp_ip4_addr_t wifi_ip;
static volatile bool hotspot_on;

// Direct comms: what's heard, oldest first, under direct_lock
static volatile uint8_t direct_channel = HOTSPOT_CHANNEL;
static volatile bool direct_long_range;
#define DIRECT_QUEUE        32
typedef struct
{
    uint8_t len;
    int8_t rssi;
    uint8_t data[RCAT_HAL_DIRECT_MAX];
} direct_msg_t;
static volatile bool direct_on;
static bool espnow_ready;
static direct_msg_t *direct_queue;      // in PSRAM: internal RAM is short
static size_t direct_head, direct_count;
static portMUX_TYPE direct_lock = portMUX_INITIALIZER_UNLOCKED;
static const uint8_t broadcast_mac[6] = { 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };

static void direct_resume(void);
static void direct_set_rate(void);

static void wifi_event_cb(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    if (base == WIFI_EVENT && id == WIFI_EVENT_STA_START)
    {
        esp_wifi_connect();
    }
    else if (base == WIFI_EVENT && id == WIFI_EVENT_STA_DISCONNECTED)
    {
        wifi_connected = false;
        if (wifi_wanted)
        {
            esp_wifi_connect();
        }
    }
    else if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP)
    {
        wifi_ip = ((ip_event_got_ip_t *)data)->ip_info.ip;
        wifi_connected = true;
        ESP_LOGI(TAG, "WiFi connected, " IPSTR, IP2STR(&wifi_ip));
    }
    else if (base == WIFI_EVENT && id == WIFI_EVENT_AP_STACONNECTED)
    {
        ESP_LOGI(TAG, "Hotspot: a phone joined");
    }
    else if (base == WIFI_EVENT && id == WIFI_EVENT_AP_STADISCONNECTED)
    {
        ESP_LOGI(TAG, "Hotspot: a phone left");
    }
}

/* Start the WiFi driver, once, for joining a network or for the hotspot. Each
 * step is done once, so trying again after a failure carries on from where
 * it stopped. */
static bool wifi_setup(void)
{
    static bool netif_ready;
    static bool wifi_failed;

    if (wifi_ready)
    {
        return true;
    }
    if (wifi_failed)
    {
        ESP_LOGE(TAG, "WiFi failed to start earlier. Restart the board to try again.");
        return false;
    }
    size_t free_internal = heap_caps_get_free_size(MALLOC_CAP_INTERNAL);
    ESP_LOGI(TAG, "Free internal RAM before WiFi: %u bytes (largest block %u)", (unsigned)free_internal,
             (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL));
    if (free_internal < WIFI_MIN_FREE_INTERNAL)
    {
        ESP_LOGE(TAG, "Not enough internal RAM for WiFi (needs about %u bytes)", (unsigned)WIFI_MIN_FREE_INTERNAL);
        return false;
    }
    if (!netif_ready)
    {
        esp_err_t err = esp_netif_init();
        if (err != ESP_OK && err != ESP_ERR_INVALID_STATE)
        {
            ESP_LOGE(TAG, "Network setup failed (%s)", esp_err_to_name(err));
            return false;
        }
        err = esp_event_loop_create_default();
        if (err != ESP_OK && err != ESP_ERR_INVALID_STATE)
        {
            ESP_LOGE(TAG, "Event loop failed (%s)", esp_err_to_name(err));
            return false;
        }
        netif_ready = true;
    }
    wifi_init_config_t init_config = WIFI_INIT_CONFIG_DEFAULT();
    esp_err_t err = esp_wifi_init(&init_config);
    if (err != ESP_OK)
    {
        ESP_LOGE(TAG, "WiFi didn't start (%s)", esp_err_to_name(err));
        wifi_failed = true;
        return false;
    }
    esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID, wifi_event_cb, NULL);
    esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP, wifi_event_cb, NULL);
    esp_wifi_set_storage(WIFI_STORAGE_RAM);     // nothing about the networks is kept in flash
    wifi_ready = true;
    return true;
}

/* Stop whichever of the two is running. */
static void wifi_stop(void)
{
    if (wifi_wanted)
    {
        wifi_wanted = false;
        wifi_connected = false;
        esp_wifi_disconnect();
    }
    hotspot_on = false;
    esp_wifi_stop();
}

bool rcat_hal_wifi_connect(const char *ssid, const char *password)
{
    static esp_netif_t *sta_netif;

    if (!wifi_setup())
    {
        return false;
    }
    wifi_stop();
    if (sta_netif == NULL)
    {
        sta_netif = esp_netif_create_default_wifi_sta();
    }
    esp_wifi_set_mode(WIFI_MODE_STA);

    wifi_config_t config = { 0 };
    // These fields don't need a terminating zero when they're full.
    memcpy(config.sta.ssid, ssid, strnlen(ssid, sizeof(config.sta.ssid)));
    memcpy(config.sta.password, password, strnlen(password, sizeof(config.sta.password)));
    esp_wifi_set_config(WIFI_IF_STA, &config);

    wifi_wanted = true;
    esp_wifi_start();
    // Power saving delays packets by up to a beacon interval, so leave it off
    // while the voice lab streams.
    esp_wifi_set_ps(WIFI_PS_NONE);
    ESP_LOGI(TAG, "Connecting to WiFi network %s. Free internal RAM: %u bytes", ssid,
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL));
    return true;
}

void rcat_hal_wifi_disconnect(void)
{
    if (!wifi_ready || !wifi_wanted)
    {
        return;
    }
    wifi_stop();
    direct_resume();
    ESP_LOGI(TAG, "WiFi off");
}

bool rcat_hal_wifi_address(char *ip, size_t len)
{
    if (!wifi_connected)
    {
        return false;
    }
    esp_ip4_addr_t addr = wifi_ip;
    snprintf(ip, len, IPSTR, IP2STR(&addr));
    return true;
}

bool rcat_hal_hotspot_start(const char *ssid, const char *password)
{
    static esp_netif_t *ap_netif;

    if (!wifi_setup())
    {
        return false;
    }
    wifi_stop();
    if (ap_netif == NULL)
    {
        ap_netif = esp_netif_create_default_wifi_ap();
        if (ap_netif == NULL)
        {
            ESP_LOGE(TAG, "Hotspot: no network interface");
            return false;
        }
        // Have the phones ask the board for DNS, so it can send every name to
        // itself and the phone shows its page on joining.
        esp_netif_ip_info_t ip_info;
        esp_netif_get_ip_info(ap_netif, &ip_info);
        esp_netif_dns_info_t dns = { 0 };
        dns.ip.u_addr.ip4.addr = ip_info.ip.addr;
        dns.ip.type = ESP_IPADDR_TYPE_V4;
        uint8_t offer_dns = 0x02;   // OFFER_DNS
        esp_netif_dhcps_stop(ap_netif);
        esp_netif_dhcps_option(ap_netif, ESP_NETIF_OP_SET, ESP_NETIF_DOMAIN_NAME_SERVER, &offer_dns,
                               sizeof(offer_dns));
        esp_netif_set_dns_info(ap_netif, ESP_NETIF_DNS_MAIN, &dns);
        // And tell newer phones straight away where the sign-in page is
        // (DHCP option 114). The option keeps the pointer, so it's static.
        static const char portal_uri[] = "http://" RCAT_HAL_HOTSPOT_ADDRESS "/";
        esp_netif_dhcps_option(ap_netif, ESP_NETIF_OP_SET, ESP_NETIF_CAPTIVEPORTAL_URI, (void *)portal_uri,
                               strlen(portal_uri));
        esp_netif_dhcps_start(ap_netif);
    }
    esp_wifi_set_mode(direct_on ? WIFI_MODE_APSTA : WIFI_MODE_AP);

    wifi_config_t config = { 0 };
    size_t ssid_len = strnlen(ssid, sizeof(config.ap.ssid));
    memcpy(config.ap.ssid, ssid, ssid_len);
    config.ap.ssid_len = (uint8_t)ssid_len;
    memcpy(config.ap.password, password, strnlen(password, sizeof(config.ap.password)));
    config.ap.channel = direct_on ? direct_channel : HOTSPOT_CHANNEL;    // with direct comms, on its channel
    config.ap.max_connection = HOTSPOT_MAX_PHONES;
    config.ap.authmode = WIFI_AUTH_WPA2_PSK;
    config.ap.pmf_cfg.capable = true;
    esp_err_t err = esp_wifi_set_config(WIFI_IF_AP, &config);
    if (err != ESP_OK)
    {
        ESP_LOGE(TAG, "Hotspot: bad settings (%s)", esp_err_to_name(err));
        return false;
    }
    // The AP defaults to 40 MHz. A setup page and a phone or two don't need
    // that, and 20 MHz takes half the band and copes better with neighbours.
    esp_wifi_set_bandwidth(WIFI_IF_AP, WIFI_BW_HT20);
    err = esp_wifi_start();
    if (err != ESP_OK)
    {
        ESP_LOGE(TAG, "Hotspot didn't start (%s)", esp_err_to_name(err));
        return false;
    }
    hotspot_on = true;
    if (direct_on)
    {
        esp_wifi_set_ps(WIFI_PS_NONE);
    }
    ESP_LOGI(TAG, "Hotspot %s on. Free internal RAM: %u bytes (largest block %u)", ssid,
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL),
             (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL));
    return true;
}

void rcat_hal_hotspot_stop(void)
{
    if (!wifi_ready || !hotspot_on)
    {
        return;
    }
    wifi_stop();
    direct_resume();
    ESP_LOGI(TAG, "Hotspot off");
}

int rcat_hal_hotspot_clients(void)
{
    wifi_sta_list_t list;
    if (!hotspot_on || esp_wifi_ap_get_sta_list(&list) != ESP_OK)
    {
        return 0;
    }
    return list.num;
}

uint32_t rcat_hal_random(void)
{
    // Truly random while the radio's on, which it is for the hotspot
    return esp_random();
}

/********************************************************************************
function:	Direct comms: ESP-NOW broadcasts
********************************************************************************/

static void direct_recv_cb(const esp_now_recv_info_t *info, const uint8_t *data, int len)
{
    if (len <= 0 || len > RCAT_HAL_DIRECT_MAX || direct_queue == NULL)
    {
        return;
    }
    taskENTER_CRITICAL(&direct_lock);
    size_t slot = (direct_head + direct_count) % DIRECT_QUEUE;
    if (direct_count == DIRECT_QUEUE)
    {
        direct_head = (direct_head + 1) % DIRECT_QUEUE;     // drop the oldest
    }
    else
    {
        direct_count++;
    }
    direct_queue[slot].len = (uint8_t)len;
    direct_queue[slot].rssi = info->rx_ctrl != NULL ? (int8_t)info->rx_ctrl->rssi : 0;
    memcpy(direct_queue[slot].data, data, (size_t)len);
    taskEXIT_CRITICAL(&direct_lock);
}

/* Have the radio listening on direct comms' channel, whatever else it's
 * doing: after the hotspot or the voice lab's network stops, or as direct
 * comms starts. */
static void direct_resume(void)
{
    if (!direct_on)
    {
        return;
    }
    wifi_mode_t mode = WIFI_MODE_NULL;
    esp_wifi_get_mode(&mode);
    if (hotspot_on)
    {
        if (mode != WIFI_MODE_APSTA)
        {
            esp_wifi_set_mode(WIFI_MODE_APSTA);     // the station's interface carries ESP-NOW
        }
    }
    else if (!wifi_wanted)
    {
        // Nothing else running: a station that joins nothing, on our channel
        esp_wifi_set_mode(WIFI_MODE_STA);
        esp_wifi_start();
        esp_wifi_set_channel(direct_channel, WIFI_SECOND_CHAN_NONE);
    }
    // Hear Long Range broadcasts as well as ordinary ones, whichever this
    // board sends: still able to join an ordinary network
    esp_wifi_set_protocol(WIFI_IF_STA, WIFI_PROTOCOL_11B | WIFI_PROTOCOL_11G | WIFI_PROTOCOL_11N | WIFI_PROTOCOL_LR);
    // Broadcasts aren't heard while the radio dozes
    esp_wifi_set_ps(WIFI_PS_NONE);
}

bool rcat_hal_direct_start(void)
{
    if (direct_on)
    {
        return true;
    }
    if (!wifi_setup())
    {
        return false;
    }
    if (direct_queue == NULL)
    {
        direct_queue = heap_caps_malloc(DIRECT_QUEUE * sizeof(direct_msg_t), MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
        if (direct_queue == NULL)
        {
            direct_queue = malloc(DIRECT_QUEUE * sizeof(direct_msg_t));
        }
        if (direct_queue == NULL)
        {
            return false;
        }
    }
    direct_on = true;
    direct_resume();
    // The radio's shared with Bluetooth: favour WiFi, as a broadcast that's
    // missed is gone, where Bluetooth tries again
    esp_coex_preference_set(ESP_COEX_PREFER_WIFI);
    if (!espnow_ready)
    {
        esp_err_t err = esp_now_init();
        if (err != ESP_OK)
        {
            ESP_LOGE(TAG, "ESP-NOW didn't start (%s)", esp_err_to_name(err));
            direct_on = false;
            return false;
        }
        esp_now_register_recv_cb(direct_recv_cb);
        esp_now_peer_info_t peer = { .channel = 0, .ifidx = WIFI_IF_STA, .encrypt = false };
        memcpy(peer.peer_addr, broadcast_mac, sizeof(broadcast_mac));
        esp_now_add_peer(&peer);
        espnow_ready = true;
    }
    direct_set_rate();
    ESP_LOGI(TAG, "Direct comms on, channel %d%s. Free internal RAM: %u bytes", direct_channel,
             direct_long_range ? ", Long Range" : "",
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL));
    return true;
}

/* Send at Long Range's 500 kb/s, or the usual 1 Mb/s. */
static void direct_set_rate(void)
{
    if (!espnow_ready)
    {
        return;
    }
    esp_now_rate_config_t rate = {
        .phymode = direct_long_range ? WIFI_PHY_MODE_LR : WIFI_PHY_MODE_11B,
        .rate = direct_long_range ? WIFI_PHY_RATE_LORA_500K : WIFI_PHY_RATE_1M_L,
    };
    esp_err_t err = esp_now_set_peer_rate_config(broadcast_mac, &rate);
    if (err != ESP_OK)
    {
        ESP_LOGW(TAG, "Direct comms: couldn't set the rate (%s)", esp_err_to_name(err));
    }
}

void rcat_hal_direct_set_radio(uint8_t channel, bool long_range)
{
    if (channel != 1 && channel != 6 && channel != 11)
    {
        channel = HOTSPOT_CHANNEL;
    }
    bool moved = channel != direct_channel;
    direct_channel = channel;
    direct_long_range = long_range;
    if (!direct_on)
    {
        return;
    }
    if (moved)
    {
        if (hotspot_on)
        {
            // The hotspot moves with it: phones on it reconnect
            wifi_config_t config;
            if (esp_wifi_get_config(WIFI_IF_AP, &config) == ESP_OK)
            {
                config.ap.channel = channel;
                esp_wifi_set_config(WIFI_IF_AP, &config);
            }
        }
        else if (!wifi_wanted)
        {
            esp_wifi_set_channel(channel, WIFI_SECOND_CHAN_NONE);
        }
    }
    direct_set_rate();
}

bool rcat_hal_direct_listen_on(uint8_t channel)
{
    if (!direct_on || hotspot_on || wifi_wanted)
    {
        return false;
    }
    return esp_wifi_set_channel(channel != 0 ? channel : direct_channel, WIFI_SECOND_CHAN_NONE) == ESP_OK;
}

void rcat_hal_direct_stop(void)
{
    if (!direct_on)
    {
        return;
    }
    direct_on = false;
    esp_coex_preference_set(ESP_COEX_PREFER_BALANCE);
    taskENTER_CRITICAL(&direct_lock);
    direct_count = 0;
    taskEXIT_CRITICAL(&direct_lock);
    if (hotspot_on)
    {
        esp_wifi_set_mode(WIFI_MODE_AP);
    }
    else if (!wifi_wanted)
    {
        esp_wifi_stop();    // nothing else needs the radio
    }
    ESP_LOGI(TAG, "Direct comms off");
}

bool rcat_hal_direct_send(const void *data, size_t len)
{
    if (!direct_on || !espnow_ready || len == 0 || len > RCAT_HAL_DIRECT_MAX)
    {
        return false;
    }
    return esp_now_send(broadcast_mac, data, len) == ESP_OK;
}

size_t rcat_hal_direct_receive(void *data, size_t max, int8_t *rssi)
{
    size_t len = 0;
    taskENTER_CRITICAL(&direct_lock);
    if (direct_count > 0 && direct_queue != NULL)
    {
        direct_msg_t *m = &direct_queue[direct_head];
        len = m->len < max ? m->len : max;
        memcpy(data, m->data, len);
        if (rssi != NULL)
        {
            *rssi = m->rssi;
        }
        direct_head = (direct_head + 1) % DIRECT_QUEUE;
        direct_count--;
    }
    taskEXIT_CRITICAL(&direct_lock);
    return len;
}
