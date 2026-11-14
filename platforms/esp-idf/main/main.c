#include "esp_core_dump.h"
#include "esp_log.h"
#include "esp_system.h"

#include "app.h"

static const char *TAG = "main";

/* Say in the log if the board restarted itself, and whether there's a core
 * dump from it to read. */
static void report_last_reset(void)
{
    esp_reset_reason_t reason = esp_reset_reason();
    const char *why = NULL;
    switch (reason)
    {
        case ESP_RST_TASK_WDT:
            why = "a task stopped (task watchdog)";
            break;
        case ESP_RST_INT_WDT:
            why = "interrupts were held off too long (interrupt watchdog)";
            break;
        case ESP_RST_WDT:
            why = "a watchdog";
            break;
        case ESP_RST_PANIC:
            why = "a crash";
            break;
        case ESP_RST_BROWNOUT:
            why = "the battery voltage dipping (brownout)";
            break;
        default:
            return;
    }
    ESP_LOGW(TAG, "Restarted after %s", why);
    if (esp_core_dump_image_check() == ESP_OK)
    {
        ESP_LOGW(TAG, "There's a core dump from it: read it with idf.py coredump-info");
    }
}

void app_main(void)
{
    report_last_reset();
    app_run();
}
