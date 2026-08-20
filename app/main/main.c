#include <stdio.h>
#include <inttypes.h>
#include "sdkconfig.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_chip_info.h"
#include "esp_flash.h"
#include "esp_system.h"

#include "spi_regs.h"
#include "midi_in.h"
#include "midi_log.h"
#include "event_bus.h"

void app_main(void)
{
    /* Print chip information */
    esp_chip_info_t chip_info;
    uint32_t flash_size;
    esp_chip_info(&chip_info);
    printf("This is %s chip with %d CPU core(s), %s%s%s%s, ",
           CONFIG_IDF_TARGET,
           chip_info.cores,
           (chip_info.features & CHIP_FEATURE_WIFI_BGN) ? "WiFi/" : "",
           (chip_info.features & CHIP_FEATURE_BT) ? "BT" : "",
           (chip_info.features & CHIP_FEATURE_BLE) ? "BLE" : "",
           (chip_info.features & CHIP_FEATURE_IEEE802154) ? ", 802.15.4 (Zigbee/Thread)" : "");

    unsigned major_rev = chip_info.revision / 100;
    unsigned minor_rev = chip_info.revision % 100;
    printf("silicon revision v%d.%d, ", major_rev, minor_rev);
    if(esp_flash_get_size(NULL, &flash_size) != ESP_OK) {
        printf("Get flash size failed");
        return;
    }

    printf("%" PRIu32 "MB %s flash\n", flash_size / (uint32_t)(1024 * 1024),
           (chip_info.features & CHIP_FEATURE_EMB_FLASH) ? "embedded" : "external");

    printf("Minimum free heap size: %" PRIu32 " bytes\n", esp_get_minimum_free_heap_size());

    // Event bus first, then the consumers that subscribe to it.
    event_bus_init();
    midi_log_init();

    // UART1 RX must init before SPI: UART1's default TX pin (GPIO7) is
    // the SPI CS pin, so the SPI init must run last and re-claim it.
    midi_in_init(0);

    fpga_spi_init(6, 5, 4, 7, 1000000); // MOSI, MISO, SCLK, CS

    int spi_value = fpga_reg_read(0x7F);
    if(spi_value == 0xA5) {
        printf("SPI slave returned expected value 0xA5\n");
    } else {
        printf("SPI slave returned unexpected value 0x%02X\n", spi_value);
    }
}
