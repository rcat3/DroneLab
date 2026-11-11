/*
 * Firmware updates (see hal.h), into the other of the two app partitions
 * (see partitions.csv), for the ESP32 boards
 */

#include "esp_log.h"
#include "esp_ota_ops.h"
#include "esp_system.h"

#include "hal.h"

static const char *TAG = "update";

static esp_ota_handle_t handle;
static const esp_partition_t *target;

bool rcat_hal_update_supported(void)
{
    return esp_ota_get_next_update_partition(NULL) != NULL;
}

bool rcat_hal_update_begin(void)
{
    rcat_hal_update_abort();
    // An update can't start until the running firmware's been confirmed,
    // and an update from it shows it works.
    rcat_hal_update_confirm();
    target = esp_ota_get_next_update_partition(NULL);
    if (target == NULL)
    {
        ESP_LOGW(TAG, "There's no partition to update into");
        return false;
    }
    // Erased as it's written, so this doesn't hold everything up erasing
    // the whole partition first.
    esp_err_t err = esp_ota_begin(target, OTA_WITH_SEQUENTIAL_WRITES, &handle);
    if (err != ESP_OK)
    {
        ESP_LOGW(TAG, "Couldn't start (%s)", esp_err_to_name(err));
        target = NULL;
        return false;
    }
    ESP_LOGI(TAG, "Writing to %s", target->label);
    return true;
}

bool rcat_hal_update_write(const void *data, size_t len)
{
    return target != NULL && esp_ota_write(handle, data, len) == ESP_OK;
}

bool rcat_hal_update_finish(void)
{
    if (target == NULL)
    {
        return false;
    }
    // Checks the image is whole and for this chip
    esp_err_t err = esp_ota_end(handle);
    const esp_partition_t *part = target;
    target = NULL;
    if (err == ESP_OK)
    {
        err = esp_ota_set_boot_partition(part);
    }
    if (err != ESP_OK)
    {
        ESP_LOGW(TAG, "The new firmware wasn't accepted (%s)", esp_err_to_name(err));
        return false;
    }
    ESP_LOGI(TAG, "Done: %s starts next", part->label);
    return true;
}

void rcat_hal_update_abort(void)
{
    if (target != NULL)
    {
        esp_ota_abort(handle);
        target = NULL;
    }
}

void rcat_hal_update_confirm(void)
{
    const esp_partition_t *running = esp_ota_get_running_partition();
    esp_ota_img_states_t state;
    if (esp_ota_get_state_partition(running, &state) == ESP_OK && state == ESP_OTA_IMG_PENDING_VERIFY)
    {
        esp_ota_mark_app_valid_cancel_rollback();
        ESP_LOGI(TAG, "The new firmware works: keeping it");
    }
}

void rcat_hal_restart(void)
{
    esp_restart();
}
