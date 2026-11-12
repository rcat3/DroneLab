/*
 * HAL for the Waveshare ESP32-S3-Touch-AMOLED-1.75
 * https://docs.waveshare.com/ESP32-S3-Touch-AMOLED-1.75
 *
 * 466x466 CO5300 AMOLED on QSPI, CST9217 touch, an AXP2101 power manager, an
 * ES8311 DAC for the speaker (through an NS4150B amplifier) and an ES7210 ADC
 * for the two microphones, a QMI8658 IMU and a TCA9554 IO expander, all but
 * the display on one I2C bus. Pin assignments are from Waveshare's schematic
 * and their board support package.
 *
 * WiFi, the hotspot, Bluetooth LE, settings and the SD card are shared with
 * the other ESP32 boards, in components/rcat_esp32.
 */

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"

#include "driver/gpio.h"
#include "driver/i2c_master.h"
#include "driver/i2s_tdm.h"
#include "driver/spi_master.h"
#include "esp_codec_dev.h"
#include "esp_codec_dev_defaults.h"
#include "esp_heap_caps.h"
#include "esp_io_expander_tca9554.h"
#include "esp_lcd_co5300.h"
#include "esp_lcd_panel_io.h"
#include "esp_lcd_panel_ops.h"
#include "esp_lcd_touch_cst9217.h"
#include "esp_log.h"
#include "esp_timer.h"

#include "hal.h"
#include "lvgl.h"
#include "rcat_esp32.h"

static const char *TAG = "board";

#define LCD_H_RES           466
#define LCD_V_RES           466

// Display (QSPI). The panel's memory starts 6 columns in from the glass.
#define LCD_HOST            SPI2_HOST
#define PIN_LCD_SCLK        38
#define PIN_LCD_D0          4
#define PIN_LCD_D1          5
#define PIN_LCD_D2          6
#define PIN_LCD_D3          7
#define PIN_LCD_CS          12
#define PIN_LCD_RST         39
#define LCD_X_GAP           6
#define LCD_PCLK_HZ         (40 * 1000 * 1000)

// I2C bus shared by everything but the display
#define PIN_I2C_SDA         15
#define PIN_I2C_SCL         14
#define PIN_TOUCH_INT       11
#define PIN_TOUCH_RST       40

// TCA9554 IO expander inputs
#define EXIO_PWR_KEY        IO_EXPANDER_PIN_NUM_4   // SYS_OUT: high while the power button is held

// AXP2101 power manager. It turns the board on with the power button by
// itself, and turns it off if the button's held for several seconds; the
// firmware turns it off sooner, after POWER_OFF_HOLD_MS, like the 1.46" board.
#define AXP_ADDR            0x34
#define AXP_REG_STATUS1     0x00
#define AXP_STATUS1_BATTERY 0x08    // a battery is connected
#define AXP_REG_STATUS2     0x01
#define AXP_STATUS2_DIR_SHIFT 5     // the battery current's direction, 2 bits
#define AXP_DIR_CHARGING    1
#define AXP_REG_GAUGE_CTRL  0x18
#define AXP_GAUGE_ENABLE    0x08
#define AXP_REG_PERCENT     0xA4    // the fuel gauge's charge, in percent
#define AXP_REG_COMMON      0x10
#define AXP_COMMON_PWROFF   0x01
#define AXP_REG_ADC_ENABLE  0x30
#define AXP_ADC_VBAT        0x01
#define AXP_REG_VBAT_H      0x34    // 14 bits in mV, high 6 bits first
#define AXP_REG_LDO_ONOFF0  0x90
#define AXP_LDO_ALDO1       0x01
#define AXP_REG_ALDO1_V     0x92
#define AXP_ALDO1_3V3       ((3300 - 500) / 100)    // 0.5 V + 0.1 V a step
// Charging. The board draws up to about 250 mA itself with the screen on, so
// the most it takes from USB is set to 500 mA, which any USB port can supply;
// the charger slows down to fit while the board's busy. 500 mA charges a
// 2000 mAh battery from flat in about 4.5 hours, and keeps it cool in the
// housing.
#define AXP_REG_INPUT_LIMIT 0x16    // bits 2:0: 0 100 mA, 1 500 mA, 2 900 mA, 3 1 A, 4 1.5 A, 5 2 A
#define AXP_INPUT_LIMIT     1       // 500 mA
#define AXP_REG_CHARGE_CUR  0x62    // bits 4:0: 25 mA steps to 200 mA (8), then 100 mA steps to 1 A (16)
#define AXP_CHARGE_CUR      11      // 500 mA
#define AXP_REG_CHARGE_VOLT 0x64    // bits 2:0: 1 4.0 V, 2 4.1 V, 3 4.2 V, 4 4.35 V, 5 4.4 V
#define AXP_CHARGE_VOLT     3       // 4.2 V, for an ordinary LiPo
#define AXP_I2C_HZ          400000
#define AXP_TIMEOUT_MS      50
#define POWER_OFF_HOLD_MS   2000
#define POWER_KEY_POLL_MS   100

// Audio. The DAC and the ADC share one I2S port, so its clocks run at one
// rate for both: the microphone's. Sound for the speaker is resampled to it.
#define I2S_PORT            I2S_NUM_0
#define PIN_I2S_MCLK        42
#define PIN_I2S_BCLK        9
#define PIN_I2S_WS          45
#define PIN_I2S_DOUT        8       // to the ES8311
#define PIN_I2S_DIN         10      // from the ES7210
#define PIN_PA_EN           46      // the NS4150B amplifier, on while high
#define AUDIO_DEBUG         0       // 1 prints the levels, echo cancelling and CPU use every second
#define AUDIO_CAPTURE       0       // 1 streams the microphones and the speaker's sound, at 16 kHz, over USB; 2 MIC1 and MIC2
#define AUDIO_SLOTS         4       // TDM: MIC1, MIC2, MIC3 (the speaker's sound) and MIC4
#define REF_GAIN_DB         24.0f   // MIC3, the speaker's sound
// The slots, in the order the ES7210 sends them in TDM
#define SLOT_MIC1           0
#define SLOT_REF            1
#define SLOT_MIC2           2
// Echo cancelling: the speaker's sound is taken out of the microphones, so
// the voice effect can be turned up further before it feeds back. It's an
// NLMS filter, run a sample at a time so it adds no delay, at 16 kHz: the
// microphones and the speaker's sound are halved in rate, and the result
// doubled back to AUDIO_RATE. The speaker's sound comes in alongside the
// microphones, so the filter only has to cover the few milliseconds the
// sound takes through the housing.
#define AEC_ENABLED         1
#define AEC_TAPS            128     // 8 ms at 16 kHz
#define AEC_STEP            0.2f
#define AEC_NEAR_WEIGHT     1.0f    // slows the learning while your voice is louder than the echo
// In the speaker housing, the speaker reaches the microphones about 20 dB
// more strongly around 1.5 kHz than at other frequencies, so that's where it
// feeds back first. Cutting that band after the echo canceller lets the voice
// effect go louder. 0 dB turns it off.
#define FEEDBACK_CUT_HZ     1450.0f
#define FEEDBACK_CUT_Q      1.2f
#define FEEDBACK_CUT_DB     -10.0f
// The microphones hear you through the mask's speaking diaphragm, which
// booms around 250 Hz and loses 15-25 dB above 2 kHz, where the consonants
// are. This puts some of it back: less boom, more treble. More treble than
// this mostly brings up hiss, as the voice is only 10-15 dB above the
// microphones' noise up there.
#define VOICE_BOOM_HZ       240.0f
#define VOICE_BOOM_Q        1.0f
#define VOICE_BOOM_DB       -8.0f
#define VOICE_TREBLE_HZ     2200.0f
#define VOICE_TREBLE_DB     8.0f
#define HALF_TAPS           31      // the low pass for halving and doubling the rate
#define AUDIO_RATE          32000   // MIC_SAMPLE_RATE in core/audio/mic.h
#define AUDIO_BLOCK_MS      5       // short, to keep the voice effect's delay down
#define AUDIO_TASK_STACK    8192    // the voice effects and the voice lab run on it too
#define AUDIO_TASK_PRIORITY 5
#define AUDIO_TASK_CORE     1       // LVGL runs on core 0
// The ES7210's microphone gain, 0 to 37.5 dB. At 30 dB a voice in the mask
// peaks about -22 dBFS, as on the 1.46" board, without clipping. Much lower
// and the voice effect's gate (-45 dBFS) cuts most of the speech.
#define MIC_GAIN_DB         30.0f
#define SPK_VOLUME          80      // the ES8311's volume, 0 to 100
#define SPK_BLOCK_FRAMES    256
#define SPK_MAX_RATIO       6       // up to this many frames out for each frame in (5.3 kHz)
#define SPK_DMA_DESC_NUM    4       // 16 ms: live sound waits a whole lap of these, so it's kept short
#define SPK_DMA_FRAME_NUM   128
#define SPK_IDLE_MS         500     // silence before the amplifier turns off, to save power
#define SPK_IDLE_POLL_MS    20
#define SPK_TASK_STACK      (24 * 1024)     // MP3 decoding, as on the 1.46" board
#define SPK_TASK_PRIORITY   6
#define SPK_TASK_CORE       1

// SD card, in 1-bit SD mode. Its D3 line is held high.
#define PIN_SD_CLK          2
#define PIN_SD_CMD          1
#define PIN_SD_D0           3
#define PIN_SD_D3           41

// The touch controller is polled at the same rate as on the 1.46" board, and
// the finger only counts as lifted after several failed reads in a row.
#define TOUCH_READ_PERIOD_MS    30
#define TOUCH_MAX_READ_ERRORS   5

// LVGL draws this many lines at a time. The CO5300 needs drawing areas that
// start on an even pixel and end on an odd one, so keep this even.
#define DRAW_BUF_LINES      32
#define DRAW_BUF_BYTES      (LCD_H_RES * DRAW_BUF_LINES * 2)

static i2c_master_bus_handle_t i2c_bus;
static i2c_master_dev_handle_t axp;
static esp_io_expander_handle_t io_expander;
static esp_lcd_panel_handle_t panel;
static esp_lcd_touch_handle_t touch;

static SemaphoreHandle_t audio_lock;
static i2s_chan_handle_t i2s_tx;
static i2s_chan_handle_t i2s_rx;
static esp_codec_dev_handle_t spk_dev;
static esp_codec_dev_handle_t mic_dev;
static bool mic_running;
static rcat_hal_audio_block_cb_t audio_cb;
static void *audio_cb_user_data;
static bool spk_running;
static rcat_hal_audio_fill_cb_t spk_cb;
static void *spk_cb_user_data;

static lv_display_t *display;
static uint8_t rotation_turns;      // clockwise quarter turns
static uint8_t *draw_buf1;
static uint8_t *draw_buf2;
static uint8_t *rotate_buf;
static SemaphoreHandle_t clear_done;

static void i2c_init(void);
static void power_init(void);
static void panel_init(void);
static void panel_clear(void);
static void touch_init(void);
static bool color_trans_done_cb(esp_lcd_panel_io_handle_t io, esp_lcd_panel_io_event_data_t *edata, void *user_ctx);
static void disp_flush_cb(lv_display_t *disp, const lv_area_t *area, uint8_t *px_map);
static void rounder_event_cb(lv_event_t *e);
static void touch_read_cb(lv_indev_t *indev, lv_indev_data_t *data);
static uint32_t tick_get_cb(void);

int rcat_hal_init(void)
{
    rcat_esp32_settings_init();
    i2c_init();
    power_init();
    panel_init();
    touch_init();
    return 0;
}

/********************************************************************************
function:	Register the display and touch screen with LVGL
parameter:
********************************************************************************/
void rcat_hal_lvgl_register(void)
{
    lv_tick_set_cb(tick_get_cb);

    display = lv_display_create(LCD_H_RES, LCD_V_RES);
    lv_display_set_flush_cb(display, disp_flush_cb);
    lv_display_set_buffers(display, draw_buf1, draw_buf2, DRAW_BUF_BYTES, LV_DISPLAY_RENDER_MODE_PARTIAL);
    lv_display_add_event_cb(display, rounder_event_cb, LV_EVENT_INVALIDATE_AREA, NULL);

    lv_indev_t *indev = lv_indev_create();
    lv_indev_set_type(indev, LV_INDEV_TYPE_POINTER);
    lv_indev_set_read_cb(indev, touch_read_cb);
    lv_timer_set_period(lv_indev_get_read_timer(indev), TOUCH_READ_PERIOD_MS);
}

void rcat_hal_display_set_rotation(uint8_t quarter_turns)
{
    // LVGL rotates in software (see disp_flush_cb) and remaps touch to match,
    // as on the 1.46" board. LVGL counts rotation counter-clockwise, so 90
    // degrees clockwise is its ROTATION_270.
    static const lv_display_rotation_t rotations[4] = {
        LV_DISPLAY_ROTATION_0,
        LV_DISPLAY_ROTATION_270,
        LV_DISPLAY_ROTATION_180,
        LV_DISPLAY_ROTATION_90,
    };
    lv_display_set_rotation(display, rotations[quarter_turns & 3]);
    rotation_turns = quarter_turns & 3;
}

void rcat_hal_backlight_set(uint8_t percent)
{
    // An AMOLED has no backlight. The panel dims itself instead.
    if (percent > 100)
    {
        percent = 100;
    }
    esp_lcd_panel_co5300_set_brightness(panel, percent);
}

/********************************************************************************
function:	AXP2101 registers
parameter:
********************************************************************************/
static bool axp_read(uint8_t reg, uint8_t *data, size_t len)
{
    return axp != NULL && i2c_master_transmit_receive(axp, &reg, 1, data, len, AXP_TIMEOUT_MS) == ESP_OK;
}

static bool axp_write(uint8_t reg, uint8_t value)
{
    const uint8_t data[2] = { reg, value };
    return axp != NULL && i2c_master_transmit(axp, data, sizeof(data), AXP_TIMEOUT_MS) == ESP_OK;
}

/* Sets the bits in mask to value, and leaves the rest as they are */
static bool axp_update(uint8_t reg, uint8_t mask, uint8_t value)
{
    uint8_t old;
    return axp_read(reg, &old, 1) && axp_write(reg, (old & ~mask) | (value & mask));
}

static bool axp_set_bits(uint8_t reg, uint8_t bits)
{
    uint8_t value;
    return axp_read(reg, &value, 1) && axp_write(reg, value | bits);
}

bool rcat_hal_battery_voltage(float *volts)
{
    uint8_t status;
    uint8_t raw[2];
    if (!axp_read(AXP_REG_STATUS1, &status, 1) || !(status & AXP_STATUS1_BATTERY)
        || !axp_read(AXP_REG_VBAT_H, raw, sizeof(raw)))
    {
        return false;
    }
    *volts = (((raw[0] & 0x3F) << 8) | raw[1]) / 1000.0f;
    return true;
}

bool rcat_hal_battery_gauge(uint8_t *percent, bool *charging)
{
    uint8_t status[2];
    if (!axp_read(AXP_REG_STATUS1, status, sizeof(status)) || !(status[0] & AXP_STATUS1_BATTERY)
        || !axp_read(AXP_REG_PERCENT, percent, 1) || *percent > 100)
    {
        return false;
    }
    *charging = ((status[1] >> AXP_STATUS2_DIR_SHIFT) & 0x03) == AXP_DIR_CHARGING;
    return true;
}

size_t rcat_hal_battery_curve(const rcat_battery_point_t **points)
{
    // Not measured yet: the core uses a typical LiPo's.
    *points = NULL;
    return 0;
}

bool rcat_hal_accel_read(float *x, float *y, float *z)
{
    float a[3];
    if (!rcat_esp32_qmi8658_read(i2c_bus, a))
    {
        return false;
    }

    // The IMU's axes in the panel's own frame (x right, y down, z out of the
    // glass, with the USB port at the bottom). Like the 1.46" board's, it's on
    // the back of the board, but with its x the other way.
    float px = a[1];
    float py = -a[0];
    *z = -a[2];

    // Then into the frame of the picture, which is turned clockwise on the panel
    for (uint8_t i = 0; i < rotation_turns; i++)
    {
        float t = px;
        px = py;
        py = -t;
    }
    *x = px;
    *y = py;
    return true;
}

/********************************************************************************
function:	Set up the I2S port and both codecs, the first time either the
            microphone or the speaker is started. Both directions run at
            AUDIO_RATE, 16-bit, in four TDM slots.
parameter:
********************************************************************************/
static bool audio_init(void)
{
    if (spk_dev != NULL)
    {
        return true;
    }

    i2s_chan_config_t chan_config = I2S_CHANNEL_DEFAULT_CONFIG(I2S_PORT, I2S_ROLE_MASTER);
    chan_config.dma_desc_num = SPK_DMA_DESC_NUM;
    chan_config.dma_frame_num = SPK_DMA_FRAME_NUM;
    chan_config.auto_clear = true;      // play silence, not old sound, if the task falls behind
    if (i2s_new_channel(&chan_config, &i2s_tx, &i2s_rx) != ESP_OK)
    {
        ESP_LOGE(TAG, "No I2S channels for the audio");
        return false;
    }
    // TDM, so the ADC can send all four of its inputs. The DAC reads it as
    // ordinary I2S: slots 0 and 1 are its left channel, 2 and 3 its right.
    i2s_tdm_config_t tdm_config = {
        .clk_cfg = I2S_TDM_CLK_DEFAULT_CONFIG(AUDIO_RATE),
        .slot_cfg = I2S_TDM_PHILIPS_SLOT_DEFAULT_CONFIG(I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_STEREO,
                                                        I2S_TDM_SLOT0 | I2S_TDM_SLOT1 | I2S_TDM_SLOT2 | I2S_TDM_SLOT3),
        .gpio_cfg = {
            .mclk = PIN_I2S_MCLK,
            .bclk = PIN_I2S_BCLK,
            .ws = PIN_I2S_WS,
            .dout = PIN_I2S_DOUT,
            .din = PIN_I2S_DIN,
        },
    };
    tdm_config.clk_cfg.mclk_multiple = I2S_MCLK_MULTIPLE_256;
    tdm_config.slot_cfg.total_slot = AUDIO_SLOTS;
    tdm_config.slot_cfg.left_align = true;
    tdm_config.slot_cfg.ws_width = 16 * AUDIO_SLOTS / 2;
    ESP_ERROR_CHECK(i2s_channel_init_tdm_mode(i2s_tx, &tdm_config));
    ESP_ERROR_CHECK(i2s_channel_init_tdm_mode(i2s_rx, &tdm_config));

    audio_codec_i2s_cfg_t i2s_cfg = {
        .port = I2S_PORT,
        .rx_handle = i2s_rx,
        .tx_handle = i2s_tx,
    };
    const audio_codec_data_if_t *data_if = audio_codec_new_i2s_data(&i2s_cfg);
    const audio_codec_gpio_if_t *gpio_if = audio_codec_new_gpio();

    // The speaker's DAC. The amplifier is switched here, not by the codec
    // driver, so it's only on while there's sound.
    audio_codec_i2c_cfg_t dac_i2c = {
        .port = I2C_NUM_0,
        .addr = ES8311_CODEC_DEFAULT_ADDR,
        .bus_handle = i2c_bus,
    };
    es8311_codec_cfg_t dac_cfg = {
        .ctrl_if = audio_codec_new_i2c_ctrl(&dac_i2c),
        .gpio_if = gpio_if,
        .codec_mode = ESP_CODEC_DEV_WORK_MODE_DAC,
        .pa_pin = -1,
        .use_mclk = true,
        .hw_gain = {
            .pa_voltage = 3.3,
            .codec_dac_voltage = 3.3,
        },
    };
    const esp_codec_dev_cfg_t spk_cfg = {
        .dev_type = ESP_CODEC_DEV_TYPE_OUT,
        .codec_if = es8311_codec_new(&dac_cfg),
        .data_if = data_if,
    };

    // The microphones' ADC: MIC1 and MIC2 are the two microphones. MIC3 is
    // the speaker's sound, for echo cancelling. MIC4 isn't connected, but
    // TDM needs at least three, and the slots come in fours.
    audio_codec_i2c_cfg_t adc_i2c = {
        .port = I2C_NUM_0,
        .addr = ES7210_CODEC_DEFAULT_ADDR,
        .bus_handle = i2c_bus,
    };
    es7210_codec_cfg_t adc_cfg = {
        .ctrl_if = audio_codec_new_i2c_ctrl(&adc_i2c),
        .mic_selected = ES7210_SEL_MIC1 | ES7210_SEL_MIC2 | ES7210_SEL_MIC3 | ES7210_SEL_MIC4,
    };
    const esp_codec_dev_cfg_t mic_cfg = {
        .dev_type = ESP_CODEC_DEV_TYPE_IN,
        .codec_if = es7210_codec_new(&adc_cfg),
        .data_if = data_if,
    };

    spk_dev = esp_codec_dev_new((esp_codec_dev_cfg_t *)&spk_cfg);
    mic_dev = esp_codec_dev_new((esp_codec_dev_cfg_t *)&mic_cfg);
    esp_codec_dev_sample_info_t fs = {
        .bits_per_sample = 16,
        .channel = AUDIO_SLOTS,
        .channel_mask = 0x0F,
        .sample_rate = AUDIO_RATE,
        .mclk_multiple = I2S_MCLK_MULTIPLE_256,
    };
    if (spk_dev == NULL || mic_dev == NULL
        || esp_codec_dev_open(spk_dev, &fs) != ESP_CODEC_DEV_OK
        || esp_codec_dev_open(mic_dev, &fs) != ESP_CODEC_DEV_OK)
    {
        ESP_LOGE(TAG, "The audio codecs didn't start");
        spk_dev = NULL;
        mic_dev = NULL;
        return false;
    }
    esp_codec_dev_set_out_vol(spk_dev, SPK_VOLUME);
    esp_codec_dev_set_in_gain(mic_dev, MIC_GAIN_DB);
    esp_codec_dev_set_in_channel_gain(mic_dev, ESP_CODEC_DEV_MAKE_CHANNEL_MASK(2), REF_GAIN_DB);

    const gpio_config_t pa_config = {
        .pin_bit_mask = 1ULL << PIN_PA_EN,
        .mode = GPIO_MODE_OUTPUT,
    };
    gpio_config(&pa_config);
    gpio_set_level(PIN_PA_EN, 0);
    ESP_LOGI(TAG, "Audio ready at %d Hz", AUDIO_RATE);
    return true;
}

static bool audio_start(void)
{
    xSemaphoreTake(audio_lock, portMAX_DELAY);
    bool ok = audio_init();
    xSemaphoreGive(audio_lock);
    return ok;
}

/********************************************************************************
function:	Read the microphones in blocks, mix them to mono and hand them to
            the callback
parameter:
********************************************************************************/
/* A low pass at 7 kHz, for halving 32 kHz to 16 kHz and back. The delay
 * line is kept twice over, so the taps always read it in one run. */
typedef struct
{
    float x[2 * HALF_TAPS];
    int pos;
} half_fir_t;

static float half_taps[HALF_TAPS];

static void half_fir_init(void)
{
    float sum = 0;
    for (int i = 0; i < HALF_TAPS; i++)
    {
        float t = i - HALF_TAPS / 2;
        float c = 7000.0f / AUDIO_RATE;
        float sinc = (t == 0) ? 2 * c : sinf(2 * (float)M_PI * c * t) / ((float)M_PI * t);
        half_taps[i] = sinc * (0.54f - 0.46f * cosf(2 * (float)M_PI * i / (HALF_TAPS - 1)));
        sum += half_taps[i];
    }
    for (int i = 0; i < HALF_TAPS; i++)
    {
        half_taps[i] /= sum;
    }
}

static void half_fir_push(half_fir_t *f, float v)
{
    f->x[f->pos] = v;
    f->x[f->pos + HALF_TAPS] = v;
    f->pos = (f->pos + 1) % HALF_TAPS;
}

static float half_fir_out(const half_fir_t *f)
{
    const float *p = &f->x[f->pos];
    float y0 = 0, y1 = 0;
    for (int k = 0; k < HALF_TAPS - 1; k += 2)
    {
        y0 += half_taps[k] * p[k];
        y1 += half_taps[k + 1] * p[k + 1];
    }
    return y0 + y1 + half_taps[HALF_TAPS - 1] * p[HALF_TAPS - 1];
}

/* Doubling the rate: the samples in between are zeros, so each of the two
 * outputs only needs every other tap. */
#define UP_TAPS ((HALF_TAPS + 1) / 2)
typedef struct
{
    float x[2 * UP_TAPS];
    int pos;
} up_fir_t;

static void up_fir(up_fir_t *f, float v, float *a, float *b)
{
    f->x[f->pos] = v;
    f->x[f->pos + UP_TAPS] = v;
    f->pos = (f->pos + 1) % UP_TAPS;
    const float *p = &f->x[f->pos];     // oldest first
    float ya = 0, yb = 0;
    for (int j = 0; j < UP_TAPS; j++)
    {
        // Tap 2j (or 2j + 1) meets the sample j back from the newest
        const float s = p[UP_TAPS - 1 - j];
        ya += half_taps[2 * j] * s;
        if (2 * j + 1 < HALF_TAPS)
        {
            yb += half_taps[2 * j + 1] * s;
        }
    }
    *a = 2.0f * ya;
    *b = 2.0f * yb;
}

static int16_t clamp16(float v)
{
    return (int16_t)(v > 32767.0f ? 32767 : (v < -32768.0f ? -32768 : v));
}

/* Hands samples to the callback in blocks of at most 10 ms */
static void deliver(int16_t *samples, size_t count)
{
    const size_t most = AUDIO_RATE / 100;
    while (count > 0)
    {
        size_t n = count > most ? most : count;
        audio_cb(samples, n, audio_cb_user_data);
        samples += n;
        count -= n;
    }
}

/* The echo canceller: an NLMS filter from the speaker's sound to what the
 * microphones hear of it. The step is normalised by the speaker's power, and
 * by what's left after cancelling, so it learns slowly while that's mostly
 * your own voice. The speaker's samples are kept twice over, so the taps
 * always read them in one run. */
typedef struct
{
    float w[AEC_TAPS];
    float x[2 * AEC_TAPS];
    int pos;
    float x_power;          // the sum of the squares of the samples in x
    float e_power;          // a running average of the square of the result
    uint32_t count;
} aec_t;

static float aec_sample(aec_t *a, float mic, float ref)
{
    float old = a->x[a->pos];
    a->x[a->pos] = ref;
    a->x[a->pos + AEC_TAPS] = ref;
    a->pos = (a->pos + 1) % AEC_TAPS;
    a->x_power += ref * ref - old * old;
    if (++a->count % 4096 == 0 || a->x_power < 0)
    {
        // Rounding builds up in the running sum, so work it out again now and then
        float sum = 0;
        for (int k = 0; k < AEC_TAPS; k++)
        {
            sum += a->x[k] * a->x[k];
        }
        a->x_power = sum;
    }

    // Four sums at once, so the multiplies don't wait on each other
    const float *x = &a->x[a->pos];
    float y0 = 0, y1 = 0, y2 = 0, y3 = 0;
    for (int k = 0; k < AEC_TAPS; k += 4)
    {
        y0 += a->w[k] * x[k];
        y1 += a->w[k + 1] * x[k + 1];
        y2 += a->w[k + 2] * x[k + 2];
        y3 += a->w[k + 3] * x[k + 3];
    }
    float e = mic - (y0 + y1 + y2 + y3);
    a->e_power += 0.002f * (e * e - a->e_power);

    float denom = a->x_power + AEC_NEAR_WEIGHT * AEC_TAPS * a->e_power + 1e-6f;
    float g = AEC_STEP * e / denom;
    for (int k = 0; k < AEC_TAPS; k += 4)
    {
        a->w[k] += g * x[k];
        a->w[k + 1] += g * x[k + 1];
        a->w[k + 2] += g * x[k + 2];
        a->w[k + 3] += g * x[k + 3];
    }
    if (!isfinite(e))
    {
        memset(a, 0, sizeof(*a));
        return mic;
    }
    return e;
}

#if AUDIO_CAPTURE
/* For tuning the echo canceller on a computer: the microphones and the
 * speaker's sound, before cancelling, as pairs of 16-bit samples, sent over
 * the USB serial port as lines of "@A <sequence> <base64>". A task of its
 * own sends them, so a slow port drops lines rather than holding up the
 * audio. */
#define CAPTURE_LINE_PAIRS  255     // 1020 bytes, a multiple of 3 for base64
#define CAPTURE_RING_PAIRS  (16 * 1024)     // a second, in PSRAM

static int16_t (*capture_ring)[2];
static volatile uint32_t capture_write;
static uint32_t capture_read;

static void capture_push(float mic, float ref)
{
    uint32_t w = capture_write;
    capture_ring[w % CAPTURE_RING_PAIRS][0] = clamp16(mic);
    capture_ring[w % CAPTURE_RING_PAIRS][1] = clamp16(ref);
    __atomic_store_n(&capture_write, w + 1, __ATOMIC_RELEASE);
}

static void capture_task(void *arg)
{
    static const char b64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    static uint8_t bytes[CAPTURE_LINE_PAIRS * 4];
    static char line[CAPTURE_LINE_PAIRS * 4 * 4 / 3 + 32];
    uint32_t seq = 0;
    while (1)
    {
        uint32_t w = __atomic_load_n(&capture_write, __ATOMIC_ACQUIRE);
        if (w - capture_read > CAPTURE_RING_PAIRS - CAPTURE_LINE_PAIRS)
        {
            capture_read = w - CAPTURE_LINE_PAIRS;      // fell behind: skip ahead, and the sequence shows it
            seq++;
        }
        if (w - capture_read < CAPTURE_LINE_PAIRS)
        {
            rcat_hal_delay_ms(5);
            continue;
        }
        for (int i = 0; i < CAPTURE_LINE_PAIRS; i++)
        {
            const int16_t *pair = capture_ring[(capture_read + i) % CAPTURE_RING_PAIRS];
            memcpy(&bytes[4 * i], pair, 4);
        }
        capture_read += CAPTURE_LINE_PAIRS;
        int n = sprintf(line, "@A %lu ", (unsigned long)seq++);
        for (size_t i = 0; i < sizeof(bytes); i += 3)
        {
            uint32_t v = bytes[i] << 16 | bytes[i + 1] << 8 | bytes[i + 2];
            line[n++] = b64[v >> 18];
            line[n++] = b64[(v >> 12) & 63];
            line[n++] = b64[(v >> 6) & 63];
            line[n++] = b64[v & 63];
        }
        line[n++] = '\n';
        fwrite(line, 1, n, stdout);
        fflush(stdout);
    }
}
#endif

/* A peaking filter (RBJ cookbook), for the feedback cut */
typedef struct
{
    float b0, b1, b2, a1, a2;
    float x1, x2, y1, y2;
} biquad_t;

static void peaking_init(biquad_t *f, float fs, float hz, float q, float db)
{
    float A = powf(10.0f, db / 40.0f);
    float w0 = 2.0f * (float)M_PI * hz / fs;
    float alpha = sinf(w0) / (2.0f * q);
    float a0 = 1.0f + alpha / A;
    *f = (biquad_t){
        .b0 = (1.0f + alpha * A) / a0,
        .b1 = -2.0f * cosf(w0) / a0,
        .b2 = (1.0f - alpha * A) / a0,
        .a1 = -2.0f * cosf(w0) / a0,
        .a2 = (1.0f - alpha / A) / a0,
    };
}

/* A high shelf (RBJ cookbook, shelf slope 1) */
static void high_shelf_init(biquad_t *f, float fs, float hz, float db)
{
    float A = powf(10.0f, db / 40.0f);
    float w0 = 2.0f * (float)M_PI * hz / fs;
    float c = cosf(w0);
    float alpha = sinf(w0) / 2.0f * sqrtf(2.0f);
    float s = 2.0f * sqrtf(A) * alpha;
    float a0 = (A + 1) - (A - 1) * c + s;
    *f = (biquad_t){
        .b0 = A * ((A + 1) + (A - 1) * c + s) / a0,
        .b1 = -2 * A * ((A - 1) + (A + 1) * c) / a0,
        .b2 = A * ((A + 1) + (A - 1) * c - s) / a0,
        .a1 = 2 * ((A - 1) - (A + 1) * c) / a0,
        .a2 = ((A + 1) - (A - 1) * c - s) / a0,
    };
}

static float biquad(biquad_t *f, float x)
{
    float y = f->b0 * x + f->b1 * f->x1 + f->b2 * f->x2 - f->a1 * f->y1 - f->a2 * f->y2;
    f->x2 = f->x1;
    f->x1 = x;
    f->y2 = f->y1;
    f->y1 = y;
    return y;
}

/********************************************************************************
function:	Read the microphones in blocks, mix them to mono, take the
            speaker out of them, and hand them to the callback
parameter:
********************************************************************************/
static void audio_task(void *arg)
{
    size_t frames = AUDIO_RATE * AUDIO_BLOCK_MS / 1000;
    int16_t *raw = heap_caps_malloc(frames * AUDIO_SLOTS * sizeof(int16_t), MALLOC_CAP_INTERNAL);
    int16_t *samples = heap_caps_malloc(frames * sizeof(int16_t), MALLOC_CAP_INTERNAL);
    assert(raw && samples);

#if AEC_ENABLED
    half_fir_init();
    static half_fir_t mic_down, ref_down;
#if AUDIO_CAPTURE == 2
    static half_fir_t mic1_down, mic2_down;
#endif
    static up_fir_t out_up;
    static aec_t aec;
    static biquad_t feedback_cut, voice_boom, voice_treble;
    peaking_init(&feedback_cut, AUDIO_RATE / 2, FEEDBACK_CUT_HZ, FEEDBACK_CUT_Q, FEEDBACK_CUT_DB);
    peaking_init(&voice_boom, AUDIO_RATE / 2, VOICE_BOOM_HZ, VOICE_BOOM_Q, VOICE_BOOM_DB);
    high_shelf_init(&voice_treble, AUDIO_RATE / 2, VOICE_TREBLE_HZ, VOICE_TREBLE_DB);
    int16_t *up = heap_caps_malloc(frames * sizeof(int16_t), MALLOC_CAP_INTERNAL);
    assert(up);
    bool odd = false;
#endif
#if AUDIO_CAPTURE
    capture_ring = heap_caps_malloc(CAPTURE_RING_PAIRS * sizeof(*capture_ring), MALLOC_CAP_SPIRAM);
    assert(capture_ring);
    xTaskCreatePinnedToCore(capture_task, "capture", 4096, NULL, 2, NULL, 0);
#endif
#if AUDIO_DEBUG
    double sq_in = 0, sq_ref = 0, sq_out = 0;
    uint32_t n_in = 0, n_out = 0;
    int64_t busy_us = 0;
    int64_t aec_us = 0;
    int64_t window_start = esp_timer_get_time();
#endif

    while (1)
    {
        if (esp_codec_dev_read(mic_dev, raw, frames * AUDIO_SLOTS * sizeof(int16_t)) != ESP_CODEC_DEV_OK)
        {
            rcat_hal_delay_ms(AUDIO_BLOCK_MS);
            continue;
        }
#if AUDIO_DEBUG
        int64_t t0 = esp_timer_get_time();
        float block_in = 0, block_ref = 0, block_out = 0;
#endif
        for (size_t i = 0; i < frames; i++)
        {
            const int16_t *f = &raw[AUDIO_SLOTS * i];
            samples[i] = (int16_t)(((int32_t)f[SLOT_MIC1] + f[SLOT_MIC2]) / 2);
#if AUDIO_DEBUG
            block_in += (float)samples[i] * samples[i];
            block_ref += (float)f[SLOT_REF] * f[SLOT_REF];
#endif
        }
#if !AEC_ENABLED
        deliver(samples, frames);
#else
        size_t n = 0;
        for (size_t i = 0; i < frames; i++)
        {
            half_fir_push(&mic_down, samples[i]);
            half_fir_push(&ref_down, raw[AUDIO_SLOTS * i + SLOT_REF]);
#if AUDIO_CAPTURE == 2
            half_fir_push(&mic1_down, raw[AUDIO_SLOTS * i + SLOT_MIC1]);
            half_fir_push(&mic2_down, raw[AUDIO_SLOTS * i + SLOT_MIC2]);
#endif
            odd = !odd;
            if (odd)
            {
                continue;
            }
            float m = half_fir_out(&mic_down);
            float r = half_fir_out(&ref_down);
#if AUDIO_CAPTURE == 2
            capture_push(half_fir_out(&mic1_down), half_fir_out(&mic2_down));
#elif AUDIO_CAPTURE
            capture_push(m, r);
#endif
            float e = aec_sample(&aec, m / 32768.0f, r / 32768.0f) * 32768.0f;
            e = biquad(&feedback_cut, e);
            e = biquad(&voice_treble, biquad(&voice_boom, e));
            float ua, ub;
            up_fir(&out_up, e, &ua, &ub);
            up[n++] = clamp16(ua);
            up[n++] = clamp16(ub);
        }
#if AUDIO_DEBUG
        for (size_t k = 0; k < n; k++)
        {
            block_out += (float)up[k] * up[k];
        }
        n_out += n;
#endif
#if AUDIO_DEBUG
        aec_us += esp_timer_get_time() - t0;    // mixing, halving, cancelling and doubling
#endif
        deliver(up, n);
#endif
#if AUDIO_DEBUG
        sq_in += block_in;
        sq_ref += block_ref;
        sq_out += block_out;
        n_in += frames;
        int64_t now = esp_timer_get_time();
        busy_us += now - t0;
        if (n_in >= AUDIO_RATE)
        {
            float mic_db = 20 * log10f(sqrtf(sq_in / n_in) / 32768 + 1e-9f);
            float ref_db = 20 * log10f(sqrtf(sq_ref / n_in) / 32768 + 1e-9f);
            float out_db = 20 * log10f(sqrtf(sq_out / (n_out ? n_out : 1)) / 32768 + 1e-9f);
            printf("mics %6.1f dB  speaker %6.1f dB  after AEC %6.1f dB  audio task %4.1f%%, AEC %4.1f%%",
                   mic_db, ref_db, out_db, 100.0f * busy_us / (now - window_start),
                   100.0f * aec_us / (now - window_start));
            // While the speaker's playing and you're quiet, how loud it is in
            // the microphones, against its own signal: the lower, the louder
            // the voice effect can go
            if (ref_db > -60)
            {
                printf("  |  pickup %+5.1f dB, after AEC %+5.1f dB", mic_db - ref_db, out_db - ref_db);
            }
            printf("\n");
            sq_in = sq_ref = sq_out = 0;
            n_in = n_out = 0;
            busy_us = 0;
            aec_us = 0;
            window_start = now;
        }
#endif
    }
}

bool rcat_hal_audio_in_start(uint32_t sample_rate, rcat_hal_audio_block_cb_t cb, void *user_data)
{
    if (mic_running)
    {
        return false;   // already running
    }
    if (sample_rate != AUDIO_RATE)
    {
        ESP_LOGE(TAG, "The microphone only runs at %d Hz", AUDIO_RATE);
        return false;
    }
    if (!audio_start())
    {
        return false;
    }

    audio_cb = cb;
    audio_cb_user_data = user_data;
    if (xTaskCreatePinnedToCore(audio_task, "audio", AUDIO_TASK_STACK, NULL, AUDIO_TASK_PRIORITY, NULL,
                                AUDIO_TASK_CORE) != pdPASS)
    {
        ESP_LOGE(TAG, "Not enough memory for the microphone task");
        return false;
    }
    mic_running = true;
    return true;
}

/********************************************************************************
function:	Resample mono sound from in_rate to AUDIO_RATE, by straight lines
            between the samples, carrying on smoothly from the last block.
            Returns how many stereo frames were written to out.
parameter:
********************************************************************************/
static size_t resample(const int16_t *in, size_t count, uint32_t in_rate, int16_t *out, size_t max_frames)
{
    static float phase;         // how far past the last input sample the next output is, 0 to 1
    static int16_t last;

    float step = (float)in_rate / AUDIO_RATE;
    size_t n = 0;
    for (size_t i = 0; i < count; i++)
    {
        int16_t next = in[i];
        while (phase < 1.0f && n < max_frames)
        {
            int16_t s = (int16_t)(last + (next - last) * phase);
            for (int k = 0; k < AUDIO_SLOTS; k++)
            {
                out[AUDIO_SLOTS * n + k] = s;
            }
            n++;
            phase += step;
        }
        phase -= 1.0f;
        last = next;
    }
    return n;
}

/********************************************************************************
function:	Ask for sound and play it. The amplifier turns off after a moment
            of silence, and back on when there's more to play. The I2S port
            keeps running for the microphones, sending silence.
parameter:
********************************************************************************/
static void speaker_task(void *arg)
{
    int16_t *frames = heap_caps_calloc(SPK_BLOCK_FRAMES * 2, sizeof(int16_t), MALLOC_CAP_INTERNAL);
    int16_t *mono = heap_caps_calloc(SPK_BLOCK_FRAMES, sizeof(int16_t), MALLOC_CAP_INTERNAL);
    size_t out_max = SPK_BLOCK_FRAMES * SPK_MAX_RATIO;
    int16_t *out = heap_caps_calloc(out_max * AUDIO_SLOTS, sizeof(int16_t), MALLOC_CAP_INTERNAL);
    assert(frames && mono && out);

    uint32_t rate = AUDIO_RATE;
    bool on = false;
    uint32_t idle_ms = 0;

    while (1)
    {
        uint32_t block_rate = rate;
        size_t count = spk_cb(frames, SPK_BLOCK_FRAMES, &block_rate, spk_cb_user_data);
        if (block_rate > 0)
        {
            rate = block_rate;
        }

        if (count == 0)
        {
            rcat_hal_delay_ms(SPK_IDLE_POLL_MS);
            if (on)
            {
                idle_ms += SPK_IDLE_POLL_MS;
                if (idle_ms >= SPK_IDLE_MS)
                {
                    gpio_set_level(PIN_PA_EN, 0);
                    on = false;
                    ESP_LOGI(TAG, "Speaker off");
                }
            }
            continue;
        }

        idle_ms = 0;
        if (!on)
        {
            gpio_set_level(PIN_PA_EN, 1);
            on = true;
            ESP_LOGI(TAG, "Speaker on, sound at %lu Hz", (unsigned long)rate);
        }

        // There's only one speaker, so mix both channels into it.
        for (size_t i = 0; i < count; i++)
        {
            mono[i] = (int16_t)(((int32_t)frames[2 * i] + frames[2 * i + 1]) / 2);
        }
        size_t n = resample(mono, count, rate, out, out_max);
        if (esp_codec_dev_write(spk_dev, out, n * AUDIO_SLOTS * sizeof(int16_t)) != ESP_CODEC_DEV_OK)
        {
            ESP_LOGW(TAG, "Speaker write failed");
        }
    }
}

bool rcat_hal_audio_out_start(rcat_hal_audio_fill_cb_t cb, void *user_data)
{
    if (spk_running)
    {
        return false;   // already running
    }
    if (!audio_start())
    {
        return false;
    }

    spk_cb = cb;
    spk_cb_user_data = user_data;
    if (xTaskCreatePinnedToCore(speaker_task, "speaker", SPK_TASK_STACK, NULL, SPK_TASK_PRIORITY, NULL,
                                SPK_TASK_CORE) != pdPASS)
    {
        ESP_LOGE(TAG, "Not enough memory for the speaker task");
        return false;
    }
    spk_running = true;
    ESP_LOGI(TAG, "Speaker ready");
    return true;
}

bool rcat_hal_storage_mount(const char **path)
{
    return rcat_esp32_sd_mount(PIN_SD_CLK, PIN_SD_CMD, PIN_SD_D0, path);
}

/********************************************************************************
function:	Power button handling. Holding the button for 2 seconds turns the
            board off.
parameter:
********************************************************************************/
static void power_key_timer_cb(void *arg)
{
    static bool released_since_boot;
    static uint32_t held_ms;

    uint32_t levels = 0;
    if (esp_io_expander_get_level(io_expander, EXIO_PWR_KEY, &levels) != ESP_OK)
    {
        return;
    }
    if (!(levels & EXIO_PWR_KEY))
    {
        released_since_boot = true;
        held_ms = 0;
        return;
    }

    // The button is usually still held from switching the board on, so
    // only count presses that start after it has been let go.
    if (!released_since_boot)
    {
        return;
    }

    held_ms += POWER_KEY_POLL_MS;
    if (held_ms >= POWER_OFF_HOLD_MS)
    {
        ESP_LOGI(TAG, "Power button held, turning off");
        rcat_hal_backlight_set(0);
        axp_set_bits(AXP_REG_COMMON, AXP_COMMON_PWROFF);
    }
}

static void i2c_init(void)
{
    const i2c_master_bus_config_t bus_config = {
        .i2c_port = I2C_NUM_0,
        .sda_io_num = PIN_I2C_SDA,
        .scl_io_num = PIN_I2C_SCL,
        .clk_source = I2C_CLK_SRC_DEFAULT,
        .glitch_ignore_cnt = 7,
        .flags.enable_internal_pullup = true,
    };
    ESP_ERROR_CHECK(i2c_new_master_bus(&bus_config, &i2c_bus));

    // Everything on it is an input, which is how it starts.
    ESP_ERROR_CHECK(esp_io_expander_new_i2c_tca9554(i2c_bus, ESP_IO_EXPANDER_I2C_TCA9554_ADDRESS_000, &io_expander));
}

static void power_init(void)
{
    audio_lock = xSemaphoreCreateMutex();

    const i2c_device_config_t dev_config = {
        .dev_addr_length = I2C_ADDR_BIT_LEN_7,
        .device_address = AXP_ADDR,
        .scl_speed_hz = AXP_I2C_HZ,
    };
    if (i2c_master_bus_add_device(i2c_bus, &dev_config, &axp) != ESP_OK)
    {
        axp = NULL;
    }

    // DCDC1 is the board's 3.3 V and ALDO1 the codecs' analog 3.3 V. The
    // AXP2101 starts both, but make sure of ALDO1, the battery voltage
    // measurement and the fuel gauge, and set up the charger.
    uint8_t was[3] = {0};
    axp_read(AXP_REG_INPUT_LIMIT, &was[0], 1);
    axp_read(AXP_REG_CHARGE_CUR, &was[1], 1);
    axp_read(AXP_REG_CHARGE_VOLT, &was[2], 1);
    bool ok = axp_write(AXP_REG_ALDO1_V, AXP_ALDO1_3V3)
              && axp_set_bits(AXP_REG_LDO_ONOFF0, AXP_LDO_ALDO1)
              && axp_set_bits(AXP_REG_ADC_ENABLE, AXP_ADC_VBAT)
              && axp_set_bits(AXP_REG_GAUGE_CTRL, AXP_GAUGE_ENABLE)
              && axp_update(AXP_REG_INPUT_LIMIT, 0x07, AXP_INPUT_LIMIT)
              && axp_update(AXP_REG_CHARGE_CUR, 0x1F, AXP_CHARGE_CUR)
              && axp_update(AXP_REG_CHARGE_VOLT, 0x07, AXP_CHARGE_VOLT);
    uint8_t now[3] = {0};
    axp_read(AXP_REG_INPUT_LIMIT, &now[0], 1);
    axp_read(AXP_REG_CHARGE_CUR, &now[1], 1);
    axp_read(AXP_REG_CHARGE_VOLT, &now[2], 1);
    if (!ok)
    {
        ESP_LOGW(TAG, "The power manager didn't answer");
    }
    ESP_LOGI(TAG, "Charger: input limit 0x%02x -> 0x%02x, current 0x%02x -> 0x%02x, voltage 0x%02x -> 0x%02x",
             was[0], now[0], was[1], now[1], was[2], now[2]);

    // The SD card's D3 line has to stay high in 1-bit SD mode.
    const gpio_config_t d3 = {
        .pin_bit_mask = 1ULL << PIN_SD_D3,
        .mode = GPIO_MODE_OUTPUT,
    };
    gpio_config(&d3);
    gpio_set_level(PIN_SD_D3, 1);

    const esp_timer_create_args_t timer_args = {
        .callback = power_key_timer_cb,
        .name = "power_key",
    };
    esp_timer_handle_t timer;
    ESP_ERROR_CHECK(esp_timer_create(&timer_args, &timer));
    ESP_ERROR_CHECK(esp_timer_start_periodic(timer, POWER_KEY_POLL_MS * 1000));
}

// Waveshare's initialization for this panel, but starting dark: the app sets
// the saved brightness once the screen is cleared.
static const co5300_lcd_init_cmd_t lcd_init_cmds[] = {
    {0xFE, (uint8_t[]){0x20}, 1, 0},
    {0x19, (uint8_t[]){0x10}, 1, 0},
    {0x1C, (uint8_t[]){0xA0}, 1, 0},
    {0xFE, (uint8_t[]){0x00}, 1, 0},
    {0xC4, (uint8_t[]){0x80}, 1, 0},
    {0x3A, (uint8_t[]){0x55}, 1, 0},
    {0x35, (uint8_t[]){0x00}, 1, 0},
    {0x53, (uint8_t[]){0x20}, 1, 0},
    {0x51, (uint8_t[]){0x00}, 1, 0},
    {0x63, (uint8_t[]){0xFF}, 1, 0},
    {0x2A, (uint8_t[]){0x00, 0x06, 0x01, 0xD7}, 4, 0},
    {0x2B, (uint8_t[]){0x00, 0x00, 0x01, 0xD1}, 4, 600},
    {0x11, NULL, 0, 600},
    {0x29, NULL, 0, 0},
};

static void panel_init(void)
{
    const spi_bus_config_t bus_config = CO5300_PANEL_BUS_QSPI_CONFIG(PIN_LCD_SCLK,
                                                                     PIN_LCD_D0, PIN_LCD_D1,
                                                                     PIN_LCD_D2, PIN_LCD_D3,
                                                                     DRAW_BUF_BYTES);
    ESP_ERROR_CHECK(spi_bus_initialize(LCD_HOST, &bus_config, SPI_DMA_CH_AUTO));

    esp_lcd_panel_io_spi_config_t io_config = CO5300_PANEL_IO_QSPI_CONFIG(PIN_LCD_CS, color_trans_done_cb, NULL);
    io_config.pclk_hz = LCD_PCLK_HZ;
    esp_lcd_panel_io_handle_t io;
    ESP_ERROR_CHECK(esp_lcd_new_panel_io_spi((esp_lcd_spi_bus_handle_t)LCD_HOST, &io_config, &io));

    const co5300_vendor_config_t vendor_config = {
        .init_cmds = lcd_init_cmds,
        .init_cmds_size = sizeof(lcd_init_cmds) / sizeof(lcd_init_cmds[0]),
        .flags = {
            .use_qspi_interface = 1,
        },
    };
    const esp_lcd_panel_dev_config_t panel_config = {
        .reset_gpio_num = PIN_LCD_RST,
        .rgb_ele_order = LCD_RGB_ELEMENT_ORDER_RGB,
        .bits_per_pixel = 16,
        .vendor_config = (void *)&vendor_config,
    };
    ESP_ERROR_CHECK(esp_lcd_new_panel_co5300(io, &panel_config, &panel));
    ESP_ERROR_CHECK(esp_lcd_panel_reset(panel));
    ESP_ERROR_CHECK(esp_lcd_panel_init(panel));
    ESP_ERROR_CHECK(esp_lcd_panel_set_gap(panel, LCD_X_GAP, 0));

    // LVGL's draw buffers, plus one for rotated output. They have to be in
    // internal RAM so the SPI DMA can read them.
    draw_buf1 = heap_caps_malloc(DRAW_BUF_BYTES, MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL);
    draw_buf2 = heap_caps_malloc(DRAW_BUF_BYTES, MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL);
    rotate_buf = heap_caps_malloc(DRAW_BUF_BYTES, MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL);
    assert(draw_buf1 && draw_buf2 && rotate_buf);

    panel_clear();
    ESP_ERROR_CHECK(esp_lcd_panel_disp_on_off(panel, true));
}

/********************************************************************************
function:	Fill the panel with black, so turning the brightness up doesn't
            show whatever was left in its memory
parameter:
********************************************************************************/
static void panel_clear(void)
{
    clear_done = xSemaphoreCreateBinary();
    memset(draw_buf1, 0, DRAW_BUF_BYTES);

    for (int y = 0; y < LCD_V_RES; y += DRAW_BUF_LINES)
    {
        int y_end = LV_MIN(y + DRAW_BUF_LINES, LCD_V_RES);
        ESP_ERROR_CHECK(esp_lcd_panel_draw_bitmap(panel, 0, y, LCD_H_RES, y_end, draw_buf1));
        xSemaphoreTake(clear_done, portMAX_DELAY);
    }
}

static void touch_init(void)
{
    esp_lcd_panel_io_i2c_config_t io_config = ESP_LCD_TOUCH_IO_I2C_CST9217_CONFIG();
    io_config.scl_speed_hz = 400000;
    esp_lcd_panel_io_handle_t io;
    ESP_ERROR_CHECK(esp_lcd_new_panel_io_i2c(i2c_bus, &io_config, &io));

    // Mirrored both ways from the panel, as in Waveshare's board support
    const esp_lcd_touch_config_t touch_config = {
        .x_max = LCD_H_RES,
        .y_max = LCD_V_RES,
        .rst_gpio_num = PIN_TOUCH_RST,
        .int_gpio_num = PIN_TOUCH_INT,
        .levels = {
            .reset = 0,
            .interrupt = 0,
        },
        .flags = {
            .mirror_x = 1,
            .mirror_y = 1,
        },
    };
    if (esp_lcd_touch_new_i2c_cst9217(io, &touch_config, &touch) != ESP_OK)
    {
        ESP_LOGE(TAG, "Touch controller not found");
        touch = NULL;
    }
}

/********************************************************************************
function:	Called from the SPI interrupt when a block of pixels has been sent
parameter:
********************************************************************************/
static bool color_trans_done_cb(esp_lcd_panel_io_handle_t io, esp_lcd_panel_io_event_data_t *edata, void *user_ctx)
{
    if (display != NULL)
    {
        lv_display_flush_ready(display);
        return false;
    }

    // Still clearing the screen in panel_clear()
    BaseType_t woken = pdFALSE;
    xSemaphoreGiveFromISR(clear_done, &woken);
    return woken == pdTRUE;
}

/********************************************************************************
function:	Send a rendered area to the panel, rotating it first if needed
parameter:
********************************************************************************/
static void disp_flush_cb(lv_display_t *disp, const lv_area_t *area, uint8_t *px_map)
{
    lv_display_rotation_t rotation = lv_display_get_rotation(disp);
    lv_area_t phys_area = *area;
    uint8_t *data = px_map;

    if (rotation != LV_DISPLAY_ROTATION_0)
    {
        int32_t w = lv_area_get_width(area);
        int32_t h = lv_area_get_height(area);
        int32_t rotated_w = (rotation == LV_DISPLAY_ROTATION_180) ? w : h;
        uint32_t src_stride = lv_draw_buf_width_to_stride(w, LV_COLOR_FORMAT_RGB565);
        uint32_t dest_stride = lv_draw_buf_width_to_stride(rotated_w, LV_COLOR_FORMAT_RGB565);

        lv_draw_sw_rotate(px_map, rotate_buf, w, h, src_stride, dest_stride, rotation, LV_COLOR_FORMAT_RGB565);
        lv_display_rotate_area(disp, &phys_area);
        data = rotate_buf;
    }

    // LVGL renders little-endian RGB565 but the panel wants the high byte first.
    lv_draw_sw_rgb565_swap(data, lv_area_get_size(&phys_area));

    // The end coordinates are exclusive. Completion is reported by color_trans_done_cb.
    esp_lcd_panel_draw_bitmap(panel, phys_area.x1, phys_area.y1, phys_area.x2 + 1, phys_area.y2 + 1, data);
}

/********************************************************************************
function:	The CO5300 needs every drawing area to start on an even pixel and
            end on an odd one, both ways. Rounding both ways covers any
            rotation.
parameter:
********************************************************************************/
static void rounder_event_cb(lv_event_t *e)
{
    lv_area_t *area = lv_event_get_param(e);
    area->x1 &= ~1;
    area->y1 &= ~1;
    area->x2 |= 1;
    area->y2 |= 1;
}

static void touch_read_cb(lv_indev_t *indev, lv_indev_data_t *data)
{
    static lv_point_t last_point;
    static lv_indev_state_t last_state = LV_INDEV_STATE_RELEASED;
    static uint8_t read_errors;

    esp_lcd_touch_point_data_t point;
    uint8_t count = 0;

    if (touch == NULL)
    {
        data->state = LV_INDEV_STATE_RELEASED;
        return;
    }

    if (esp_lcd_touch_read_data(touch) != ESP_OK)
    {
        // Report the last state again rather than a lift in the middle of a drag.
        if (++read_errors >= TOUCH_MAX_READ_ERRORS)
        {
            last_state = LV_INDEV_STATE_RELEASED;
        }
    }
    else
    {
        read_errors = 0;
        esp_lcd_touch_get_data(touch, &point, &count, 1);
        if (count > 0)
        {
            last_point.x = point.x;
            last_point.y = point.y;
            last_state = LV_INDEV_STATE_PRESSED;
        }
        else
        {
            last_state = LV_INDEV_STATE_RELEASED;
        }
    }

    data->point = last_point;
    data->state = last_state;
}

static uint32_t tick_get_cb(void)
{
    return (uint32_t)(esp_timer_get_time() / 1000);
}
