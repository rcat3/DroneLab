/*
 * HAL pieces that are the same on every ESP32 board
 */

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "driver/gpio.h"
#include "driver/sdmmc_host.h"
#include "esp_log.h"
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

void rcat_hal_delay_ms(uint32_t ms)
{
    TickType_t ticks = pdMS_TO_TICKS(ms);
    vTaskDelay(ticks > 0 ? ticks : 1);
}

/* The BOOT button, on GPIO0 on every ESP32-S3 board. It only matters at reset
 * (held then, the board waits for new firmware over USB), so once it's
 * running it's free. It has a pull-up on the board and reads low while it's
 * pressed. */
#define BUTTON_GPIO         GPIO_NUM_0
#define BUTTON_SETTLE_US    30000       // a press or release has to last this long, for the contacts' bounce

bool rcat_hal_button_pressed(void)
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
        return false;
    }

    bool now_down = gpio_get_level(BUTTON_GPIO) == 0;
    int64_t now = esp_timer_get_time();
    if (now_down == down)
    {
        changed_us = 0;
        return false;
    }
    if (changed_us == 0)
    {
        changed_us = now;
        return false;
    }
    if (now - changed_us < BUTTON_SETTLE_US)
    {
        return false;
    }
    down = now_down;
    changed_us = 0;
    return down;
}
