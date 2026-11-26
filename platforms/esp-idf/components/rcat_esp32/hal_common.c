/*
 * HAL pieces that are the same on every ESP32 board
 */

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/idf_additions.h"

#include "driver/gpio.h"
#include "driver/sdmmc_host.h"
#include "driver/usb_serial_jtag.h"
#include "driver/usb_serial_jtag_vfs.h"
#include "esp_app_desc.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "esp_timer.h"
#include "esp_vfs_fat.h"

#include "hal.h"
#include "rcat_esp32.h"

static const char *TAG = "storage";

#define SD_MOUNT_POINT      "/sdcard"

bool rcat_esp32_sd_mount(int clk, int cmd, int d0, const char **path)
{
    static bool mounted;

    if (!mounted)
    {
        sdmmc_host_t host = SDMMC_HOST_DEFAULT();
        sdmmc_slot_config_t slot = SDMMC_SLOT_CONFIG_DEFAULT();
        slot.width = 1;
        slot.clk = clk;
        slot.cmd = cmd;
        slot.d0 = d0;
        slot.flags |= SDMMC_SLOT_FLAG_INTERNAL_PULLUP;

        // Never format the card, even if it can't be read. It may have files
        // someone wants to keep.
        const esp_vfs_fat_sdmmc_mount_config_t mount_config = {
            .format_if_mount_failed = false,
            .max_files = 4,
            .allocation_unit_size = 16 * 1024,
        };
        sdmmc_card_t *card;
        esp_err_t err = esp_vfs_fat_sdmmc_mount(SD_MOUNT_POINT, &host, &slot, &mount_config, &card);
        if (err != ESP_OK)
        {
            ESP_LOGW(TAG, "No SD card (%s)", esp_err_to_name(err));
            return false;
        }
        ESP_LOGI(TAG, "SD card mounted, %llu MB", ((uint64_t)card->csd.capacity) * card->csd.sector_size / (1024 * 1024));
        mounted = true;
    }

    *path = SD_MOUNT_POINT;
    return true;
}

bool rcat_hal_storage_space(uint64_t *total, uint64_t *free_bytes)
{
    return esp_vfs_fat_info(SD_MOUNT_POINT, total, free_bytes) == ESP_OK;
}

uint32_t rcat_hal_millis(void)
{
    return (uint32_t)(esp_timer_get_time() / 1000);
}

void rcat_hal_delay_ms(uint32_t ms)
{
    TickType_t ticks = pdMS_TO_TICKS(ms);
    vTaskDelay(ticks > 0 ? ticks : 1);
}

// Background work runs on core 0, beside LVGL, as the audio has core 1. It
// runs ahead of LVGL, which only makes the screen a moment late, but behind
// Bluetooth and WiFi.
#define TASK_CORE       0
#define TASK_PRIORITY   3

bool rcat_hal_task_start(const char *name, void (*fn)(void *arg), void *arg, size_t stack_size)
{
    // Stacks in PSRAM, as internal RAM is short. The tasks never write the
    // flash, which is when PSRAM can't be reached.
    BaseType_t ok = xTaskCreatePinnedToCoreWithCaps(fn, name, stack_size, arg, TASK_PRIORITY, NULL, TASK_CORE,
                                                    MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (ok != pdPASS)
    {
        ESP_LOGE("task", "Couldn't start task %s", name);
        return false;
    }
    return true;
}

/* The BOOT button, on GPIO0 on every ESP32-S3 board. It only matters at reset
 * (held then, the board waits for new firmware over USB), so once it's
 * running it's free. It has a pull-up on the board and reads low while it's
 * pressed. */
#define BUTTON_GPIO         GPIO_NUM_0
#define BUTTON_SETTLE_US    30000       // a press or release has to last this long, for the contacts' bounce

static bool (*power_key_held)(void);
static bool button_press;               // pressed since rcat_hal_button_pressed() last said so
static bool screenshot_press;           // pressed with PWR held, since rcat_hal_screenshot_pressed() last said so

void rcat_esp32_set_power_key(bool (*held)(void))
{
    power_key_held = held;
}

/* Watch the button, and note each press, as an ordinary one or, with PWR
 * held, a screenshot. Either of its two readers keeps it going. */
static void button_poll(void)
{
    static bool ready;
    static bool down;           // what it's settled at
    static int64_t changed_us;  // when it last read differently from that

    if (!ready)
    {
        const gpio_config_t config = {
            .pin_bit_mask = 1ULL << BUTTON_GPIO,
            .mode = GPIO_MODE_INPUT,
            .pull_up_en = GPIO_PULLUP_ENABLE,
        };
        gpio_config(&config);
        // Held from startup doesn't count as a press.
        down = gpio_get_level(BUTTON_GPIO) == 0;
        ready = true;
        return;
    }

    bool now_down = gpio_get_level(BUTTON_GPIO) == 0;
    int64_t now = esp_timer_get_time();
    if (now_down == down)
    {
        changed_us = 0;
        return;
    }
    if (changed_us == 0)
    {
        changed_us = now;
        return;
    }
    if (now - changed_us < BUTTON_SETTLE_US)
    {
        return;
    }
    down = now_down;
    changed_us = 0;
    if (down)
    {
        if (power_key_held != NULL && power_key_held())
        {
            screenshot_press = true;
        }
        else
        {
            button_press = true;
        }
    }
}

bool rcat_hal_button_pressed(void)
{
    button_poll();
    bool pressed = button_press;
    button_press = false;
    return pressed;
}

bool rcat_hal_screenshot_pressed(void)
{
    button_poll();
    bool pressed = screenshot_press;
    screenshot_press = false;
    return pressed;
}

size_t rcat_hal_console_read(char *buf, size_t cap)
{
    static bool ready;

    if (!ready)
    {
        // The log goes out through the driver from here on, so it doesn't
        // get in the way of reading.
        usb_serial_jtag_driver_config_t config = USB_SERIAL_JTAG_DRIVER_CONFIG_DEFAULT();
        if (usb_serial_jtag_driver_install(&config) != ESP_OK)
        {
            return 0;
        }
        usb_serial_jtag_vfs_use_driver();
        ready = true;
    }
    int n = usb_serial_jtag_read_bytes(buf, cap, 0);
    return n > 0 ? (size_t)n : 0;
}

const char *rcat_hal_firmware_version(void)
{
    // ESP-IDF builds `git describe` into the firmware
    return esp_app_get_description()->version;
}

bool rcat_hal_mac_address(uint8_t mac[6])
{
    // Read from the chip's eFuses, so it needs no WiFi running
    return esp_read_mac(mac, ESP_MAC_WIFI_STA) == ESP_OK;
}

bool rcat_hal_bt_mac_address(uint8_t mac[6])
{
    return esp_read_mac(mac, ESP_MAC_BT) == ESP_OK;
}

const char *rcat_hal_firmware_built(void)
{
    static char built[40];  // the date and time fields are 16 bytes each
    if (built[0] == '\0')
    {
        const esp_app_desc_t *d = esp_app_get_description();
        snprintf(built, sizeof(built), "%s %s", d->date, d->time);
    }
    return built;
}
