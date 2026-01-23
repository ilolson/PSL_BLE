#include <BTstackLib.h>
#include <Adafruit_NeoPixel.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(ARDUINO_ARCH_RP2040)
#include "hardware/watchdog.h"
#endif

namespace {

constexpr uint16_t kLedCount = 300;
constexpr uint8_t kPacketBuffer = 128;
constexpr uint8_t kBluetoothDataTypeFlags = 0x01;
constexpr uint8_t kBluetoothDataTypeComplete128BitUUIDs = 0x07;
constexpr uint8_t kBluetoothDataTypeCompleteLocalName = 0x09;
constexpr float kMinBrightness = 0.0f;
constexpr float kMaxBrightness = 1.0f;
constexpr float kDefaultHue = 25.0f;
constexpr float kDefaultSaturation = 1.0f;
constexpr float kDefaultBrightness = 125.0f / 255.0f;
#ifndef PSL_LED_PIN
#define PSL_LED_PIN 0
#endif

constexpr uint8_t kFrameCommandId = 0xA0;

const char kBleDeviceName[] = "PSL";
constexpr size_t kDeviceNameMaxLen = sizeof(kBleDeviceName) + 4;

const uint8_t kServiceUuid[16] = {
    0x21, 0x43, 0x65, 0x87, 0xa9, 0xcb, 0xed, 0x0f,
    0x10, 0x32, 0x54, 0x76, 0x98, 0xba, 0xdc, 0xfe
};

Adafruit_NeoPixel strip(kLedCount, PSL_LED_PIN, NEO_GRB + NEO_KHZ800);

uint16_t segment_start = 0;
uint16_t segment_end = kLedCount - 1;
float current_hue = kDefaultHue;
float current_saturation = kDefaultSaturation;
float current_brightness = kDefaultBrightness;
float hue_offset = 0.0f;
float brightness_offset = 0.0f;

bool parse_frame_packet(const uint8_t *data, size_t len);
void apply_frame_run(uint16_t start, uint16_t length, uint8_t r, uint8_t g, uint8_t b);

char device_name[kDeviceNameMaxLen + 1] = {};
size_t device_name_len = 0;
uint8_t adv_data[31] = {};
uint8_t scan_data[31] = {};
uint8_t adv_data_len = 0;
uint8_t scan_data_len = 0;
bool advertising_active = false;

float clampf(float value, float min_value, float max_value) {
    if (value < min_value) {
        return min_value;
    }
    if (value > max_value) {
        return max_value;
    }
    return value;
}

void hsv_to_rgb(float h, float s, float v, uint8_t *r, uint8_t *g, uint8_t *b) {
    h = fmodf(h, 360.0f);
    if (h < 0.0f) {
        h += 360.0f;
    }
    float c = v * s;
    float x = c * (1.0f - fabsf(fmodf(h / 60.0f, 2.0f) - 1.0f));
    float m = v - c;
    float r1 = 0.0f;
    float g1 = 0.0f;
    float b1 = 0.0f;

    if (h < 60.0f) {
        r1 = c;
        g1 = x;
    } else if (h < 120.0f) {
        r1 = x;
        g1 = c;
    } else if (h < 180.0f) {
        g1 = c;
        b1 = x;
    } else if (h < 240.0f) {
        g1 = x;
        b1 = c;
    } else if (h < 300.0f) {
        r1 = x;
        b1 = c;
    } else {
        r1 = c;
        b1 = x;
    }

    *r = static_cast<uint8_t>(clampf((r1 + m) * 255.0f, 0.0f, 255.0f));
    *g = static_cast<uint8_t>(clampf((g1 + m) * 255.0f, 0.0f, 255.0f));
    *b = static_cast<uint8_t>(clampf((b1 + m) * 255.0f, 0.0f, 255.0f));
}

void write_strip_color(uint32_t color) {
    for (uint16_t i = 0; i < kLedCount; ++i) {
        if (i >= segment_start && i <= segment_end) {
            strip.setPixelColor(i, color);
        } else {
            strip.setPixelColor(i, 0);
        }
    }
    strip.show();
}

void render_color_from_state() {
    float adjusted_hue = fmodf(current_hue + hue_offset, 360.0f);
    if (adjusted_hue < 0.0f) {
        adjusted_hue += 360.0f;
    }
    float adjusted_brightness = clampf(
        current_brightness + brightness_offset,
        kMinBrightness,
        kMaxBrightness
    );

    uint8_t r = 0;
    uint8_t g = 0;
    uint8_t b = 0;
    hsv_to_rgb(adjusted_hue, current_saturation, adjusted_brightness, &r, &g, &b);
    uint32_t grb = strip.Color(r, g, b);
    write_strip_color(grb);
}

void clamp_segment_bounds() {
    if (segment_start >= kLedCount) {
        segment_start = kLedCount - 1;
    }
    if (segment_end >= kLedCount) {
        segment_end = kLedCount - 1;
    }
    if (segment_start > segment_end) {
        segment_end = segment_start;
    }
}

void set_segment_start(uint32_t start) {
    uint32_t index = start;
    if (index >= kLedCount) {
        index = kLedCount - 1;
    }
    segment_start = static_cast<uint16_t>(index);
    clamp_segment_bounds();
    render_color_from_state();
}

void set_segment_end(uint32_t end) {
    uint32_t index = end;
    if (index >= kLedCount) {
        index = kLedCount - 1;
    }
    segment_end = static_cast<uint16_t>(index);
    clamp_segment_bounds();
    render_color_from_state();
}

void set_hue(float degrees) {
    float normalized = fmodf(degrees, 360.0f);
    if (normalized < 0.0f) {
        normalized += 360.0f;
    }
    current_hue = normalized;
    hue_offset = 0.0f;
    render_color_from_state();
}

void adjust_hue(float delta) {
    hue_offset = fmodf(hue_offset + delta, 360.0f);
    if (hue_offset < 0.0f) {
        hue_offset += 360.0f;
    }
    render_color_from_state();
}

void set_brightness(float percent) {
    float normalized = percent / 100.0f;
    current_brightness = clampf(normalized, kMinBrightness, kMaxBrightness);
    brightness_offset = 0.0f;
    render_color_from_state();
}

void adjust_brightness(float delta) {
    float desired = clampf(
        current_brightness + brightness_offset + delta,
        kMinBrightness,
        kMaxBrightness
    );
    brightness_offset = desired - current_brightness;
    render_color_from_state();
}

void render_motion_color(float pitch, float roll, float yaw) {
    float norm_roll = clampf((roll + 3.14159f) / (2.0f * 3.14159f), 0.0f, 1.0f);
    float norm_yaw = clampf((yaw + 3.14159f) / (2.0f * 3.14159f), 0.0f, 1.0f);
    float norm_pitch = clampf((pitch + (3.14159f / 2.0f)) / 3.14159f, 0.0f, 1.0f);
    float hue = fmodf(norm_yaw * 360.0f + norm_roll * 120.0f, 360.0f);
    float saturation = clampf(0.35f + norm_roll * 0.65f, 0.2f, 1.0f);
    float brightness = clampf(
        0.2f + norm_pitch * 0.8f,
        kMinBrightness,
        kMaxBrightness
    );

    current_hue = hue;
    current_saturation = saturation;
    current_brightness = brightness;
    hue_offset = 0.0f;
    brightness_offset = 0.0f;
    render_color_from_state();
}

void reset_system() {
#if defined(ARDUINO_ARCH_RP2040)
    watchdog_reboot(0, 0, 0);
#elif defined(NVIC_SystemReset)
    NVIC_SystemReset();
#else
    Serial.println("Reset requested but unsupported on this platform.");
#endif
}

bool parse_prefixed_float(const char *buffer, const char *prefix, float *value) {
    const size_t prefix_len = strlen(prefix);
    if (strncmp(buffer, prefix, prefix_len) != 0) {
        return false;
    }
    const char *start = buffer + prefix_len;
    char *end_ptr = nullptr;
    float parsed = strtof(start, &end_ptr);
    if (end_ptr == start) {
        return false;
    }
    *value = parsed;
    return true;
}

bool parse_segment_command(const char *buffer, const char *prefix, uint32_t *index) {
    const size_t prefix_len = strlen(prefix);
    if (strncmp(buffer, prefix, prefix_len) != 0) {
        return false;
    }
    const char *start = buffer + prefix_len;
    char *end_ptr = nullptr;
    unsigned long parsed = strtoul(start, &end_ptr, 10);
    if (end_ptr == start) {
        return false;
    }
    *index = static_cast<uint32_t>(parsed);
    return true;
}

bool parse_motion_triplet(const char *buffer, float *pitch, float *roll, float *yaw) {
    char *end_ptr = nullptr;
    *pitch = strtof(buffer, &end_ptr);
    if (end_ptr == buffer || *end_ptr != ',') {
        return false;
    }
    const char *next = end_ptr + 1;
    *roll = strtof(next, &end_ptr);
    if (end_ptr == next || *end_ptr != ',') {
        return false;
    }
    next = end_ptr + 1;
    *yaw = strtof(next, &end_ptr);
    return end_ptr != next;
}

void configure_random_address() {
    uint8_t addr[6];
    for (size_t i = 0; i < 6; ++i) {
        addr[i] = static_cast<uint8_t>(random(0, 256));
    }
    addr[5] = (addr[5] & 0x3F) | 0xC0;
    BTstack.setPublicBdAddr(addr);
    Serial.printf(
        "Using random static addr %02X:%02X:%02X:%02X:%02X:%02X\n",
        addr[5], addr[4], addr[3], addr[2], addr[1], addr[0]
    );
}

void handle_motion_packet(const char *packet, size_t len) {
    char buffer[kPacketBuffer] = {};
    size_t copy_len = len < sizeof(buffer) - 1 ? len : sizeof(buffer) - 1;
    memcpy(buffer, packet, copy_len);
    buffer[copy_len] = '\0';

    if (strncmp(buffer, "RESET", 5) == 0) {
        Serial.println("Reset command received.");
        delay(50);
        reset_system();
        return;
    }

    float value = 0.0f;
    if (parse_prefixed_float(buffer, "H_SET,", &value)) {
        set_hue(value);
        return;
    }
    if (parse_prefixed_float(buffer, "B_SET,", &value)) {
        set_brightness(value);
        return;
    }
    if (parse_prefixed_float(buffer, "H,", &value)) {
        adjust_hue(value);
        return;
    }
    if (parse_prefixed_float(buffer, "B,", &value)) {
        adjust_brightness(value);
        return;
    }

    uint32_t index = 0;
    if (parse_segment_command(buffer, "SEG_START,", &index)) {
        set_segment_start(index > 0 ? index - 1 : 0);
        return;
    }
    if (parse_segment_command(buffer, "SEG_END,", &index)) {
        set_segment_end(index > 0 ? index - 1 : 0);
        return;
    }

    float pitch = 0.0f;
    float roll = 0.0f;
    float yaw = 0.0f;
    if (parse_motion_triplet(buffer, &pitch, &roll, &yaw)) {
        render_motion_color(pitch, roll, yaw);
        return;
    }

    Serial.print("Unrecognized BLE packet: ");
    Serial.println(buffer);
}

void apply_frame_run(uint16_t start, uint16_t length, uint8_t r, uint8_t g, uint8_t b) {
    if (length == 0) {
        return;
    }
    const uint16_t end = start + length;
    uint32_t color = strip.Color(r, g, b);
    for (uint16_t i = start; i < end && i < kLedCount; ++i) {
        strip.setPixelColor(i, color);
    }
}

bool parse_frame_packet(const uint8_t *data, size_t length) {
    if (!data || length < 3) {
        return false;
    }
    if (data[0] != kFrameCommandId) {
        return false;
    }
    if (data[1] != 1) {
        Serial.println("Unsupported frame version");
        return true;
    }

    const uint8_t run_count = data[2];
    size_t offset = 3;
    for (uint8_t i = 0; i < run_count; ++i) {
        if (offset + 7 > length) {
            Serial.println("Frame truncated");
            break;
        }

        uint16_t start = static_cast<uint16_t>(data[offset] | (data[offset + 1] << 8));
        offset += 2;
        uint16_t run_length = static_cast<uint16_t>(data[offset] | (data[offset + 1] << 8));
        offset += 2;
        uint8_t r = data[offset++];
        uint8_t g = data[offset++];
        uint8_t b = data[offset++];
        apply_frame_run(start, run_length, r, g, b);
    }

    strip.show();
    return true;
}

void update_device_name_suffix() {
    strncpy(device_name, kBleDeviceName, sizeof(device_name) - 1);
    device_name[sizeof(device_name) - 1] = '\0';
    device_name_len = strlen(device_name);
}

void copy_uuid_le(uint8_t *dest, const uint8_t *uuid) {
    for (size_t i = 0; i < 16; ++i) {
        dest[i] = uuid[15 - i];
    }
}

void prepare_advertising_payload() {
    adv_data_len = 0;
    adv_data[adv_data_len++] = 2;
    adv_data[adv_data_len++] = kBluetoothDataTypeFlags;
    adv_data[adv_data_len++] = 0x06;

    adv_data[adv_data_len++] = static_cast<uint8_t>(1 + sizeof(kServiceUuid));
    adv_data[adv_data_len++] = kBluetoothDataTypeComplete128BitUUIDs;
    copy_uuid_le(&adv_data[adv_data_len], kServiceUuid);
    adv_data_len += sizeof(kServiceUuid);

    scan_data_len = 0;
    uint8_t name_len = static_cast<uint8_t>(min(device_name_len, sizeof(scan_data) - 2));
    scan_data[scan_data_len++] = static_cast<uint8_t>(1 + name_len);
    scan_data[scan_data_len++] = kBluetoothDataTypeCompleteLocalName;
    memcpy(&scan_data[scan_data_len], device_name, name_len);
    scan_data_len += name_len;
}

void start_advertising() {
    prepare_advertising_payload();
    BTstack.setAdvData(adv_data_len, adv_data);
    BTstack.setScanData(scan_data_len, scan_data);
    BTstack.startAdvertising();
    advertising_active = true;
    Serial.print("Advertising as ");
    Serial.println(device_name);
}

void deviceConnectedCallback(BLEStatus status, BLEDevice *device) {
    (void)device;
    if (status == BLE_STATUS_OK) {
        Serial.println("Device connected.");
    } else {
        Serial.print("Connect status ");
        Serial.println(status);
    }
}

void deviceDisconnectedCallback(BLEDevice *device) {
    (void)device;
    Serial.println("Device disconnected.");
    advertising_active = false;
    start_advertising();
}

int gattWriteCallback(uint16_t characteristic_id, uint8_t *buffer, uint16_t size) {
    (void)characteristic_id;
    if (!buffer || size == 0) {
        return 0;
    }

    if (parse_frame_packet(buffer, size)) {
        return 0;
    }

    size_t copy_len = size < kPacketBuffer - 1 ? size : kPacketBuffer - 1;
    char payload[kPacketBuffer] = {};
    memcpy(payload, buffer, copy_len);
    payload[copy_len] = '\0';
    Serial.print("BLE write: ");
    Serial.println(payload);
    handle_motion_packet(payload, copy_len);
    return 0;
}

void add_gap_service() {
    BTstack.addGATTService(new UUID("1800"));
    BTstack.addGATTCharacteristic(
        new UUID("2A00"),
        ATT_PROPERTY_READ,
        reinterpret_cast<uint8_t *>(device_name),
        static_cast<uint16_t>(device_name_len)
    );
    static uint8_t appearance_value[2] = {0x00, 0x00};
    BTstack.addGATTCharacteristic(
        new UUID("2A01"),
        ATT_PROPERTY_READ,
        appearance_value,
        sizeof(appearance_value)
    );
}

void init_ble() {
    update_device_name_suffix();
    BTstack.setBLEDeviceConnectedCallback(deviceConnectedCallback);
    BTstack.setBLEDeviceDisconnectedCallback(deviceDisconnectedCallback);
    BTstack.setGATTCharacteristicWrite(gattWriteCallback);
    BTstack.enablePacketLogger();
    BTstack.enableDebugLogger();
    configure_random_address();

    add_gap_service();
    BTstack.addGATTService(new UUID("21436587-A9CB-ED0F-1032-547698BADCFE"));
    BTstack.addGATTCharacteristicDynamic(
        new UUID("0C1D2E3F-4051-6273-8495-A6B7C8D9EAFB"),
        ATT_PROPERTY_READ | ATT_PROPERTY_WRITE | ATT_PROPERTY_WRITE_WITHOUT_RESPONSE,
        0
    );

    BTstack.setup(device_name);
    start_advertising();
}

} // namespace

void setup() {
    Serial.begin(115200);
    while (!Serial && millis() < 1500) {
        delay(10);
    }
    randomSeed(static_cast<uint32_t>(micros()));

    strip.begin();
    strip.show();
    render_color_from_state();

    init_ble();
}

void loop() {
    BTstack.loop();
}
