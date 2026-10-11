// cli_system.c — the serial console's system commands
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// info, mem, tasks, uptime, df, log and reboot: what ESP-IDF and FreeRTOS
// can report about the running firmware. tasks needs
// CONFIG_FREERTOS_USE_TRACE_FACILITY and CONFIG_FREERTOS_GENERATE_RUN_TIME_STATS.

#include "cli.h"

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "esp_app_desc.h"
#include "esp_chip_info.h"
#include "esp_flash.h"
#include "esp_heap_caps.h"
#include "esp_idf_version.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "esp_vfs_fat.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "console.h"
#include "storage.h"

static const char *reset_reason(esp_reset_reason_t r)
{
    switch (r) {
    case ESP_RST_POWERON:   return "power-on";
    case ESP_RST_EXT:       return "external pin";
    case ESP_RST_SW:        return "software (esp_restart)";
    case ESP_RST_PANIC:     return "panic";
    case ESP_RST_INT_WDT:   return "interrupt watchdog";
    case ESP_RST_TASK_WDT:  return "task watchdog";
    case ESP_RST_WDT:       return "other watchdog";
    case ESP_RST_DEEPSLEEP: return "deep sleep";
    case ESP_RST_BROWNOUT:  return "brownout";
    case ESP_RST_USB:       return "USB";
    case ESP_RST_JTAG:      return "JTAG";
    default:                return "unknown";
    }
}

static int cmd_info(int argc, char **argv)
{
    (void)argc; (void)argv;
    const esp_app_desc_t *ad = esp_app_get_description();
    esp_chip_info_t chip;
    esp_chip_info(&chip);
    uint32_t flash = 0;
    esp_flash_get_size(NULL, &flash);
    uint8_t mac[6] = {0};
    esp_read_mac(mac, ESP_MAC_BT);
    printf("  firmware  %s, built %s %s, ESP-IDF %s\n", ad->version, ad->date, ad->time,
           esp_get_idf_version());
    printf("  chip      %s rev v%d.%d, %d core%s, %" PRIu32 " MB flash\n", CONFIG_IDF_TARGET,
           chip.revision / 100, chip.revision % 100, chip.cores, chip.cores == 1 ? "" : "s",
           flash / (1024 * 1024));
    printf("  BLE MAC   %02x:%02x:%02x:%02x:%02x:%02x\n",
           mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
    printf("  reset     %s\n", reset_reason(esp_reset_reason()));
    return 0;
}

static int cmd_mem(int argc, char **argv)
{
    (void)argc; (void)argv;
    uint32_t caps = MALLOC_CAP_8BIT;
    printf("  heap      %u free of %u bytes, lowest ever %u, largest block %u\n",
           (unsigned)heap_caps_get_free_size(caps), (unsigned)heap_caps_get_total_size(caps),
           (unsigned)heap_caps_get_minimum_free_size(caps),
           (unsigned)heap_caps_get_largest_free_block(caps));
    return 0;
}

static int cmd_tasks(int argc, char **argv)
{
    (void)argc; (void)argv;
    UBaseType_t n = uxTaskGetNumberOfTasks() + 2;   // room for tasks created meanwhile
    TaskStatus_t *st = malloc(n * sizeof *st);
    if (!st) { printf("tasks: out of memory\n"); return 1; }
    configRUN_TIME_COUNTER_TYPE total = 0;
    n = uxTaskGetSystemState(st, n, &total);
    static const char *const states[] = { "run", "ready", "block", "susp", "del", "?" };
    printf("  %-16s %-5s %4s %6s %5s\n", "task", "state", "prio", "stack", "cpu");
    for (UBaseType_t i = 0; i < n; i++) {
        unsigned state = st[i].eCurrentState < 5 ? (unsigned)st[i].eCurrentState : 5;
        double cpu = total ? 100.0 * (double)st[i].ulRunTimeCounter / (double)total : 0.0;
        printf("  %-16s %-5s %4u %6u %4.1f%%\n", st[i].pcTaskName, states[state],
               (unsigned)st[i].uxCurrentPriority, (unsigned)st[i].usStackHighWaterMark, cpu);
    }
    printf("  stack: the least free stack each task has had, in bytes; cpu: since boot\n");
    free(st);
    return 0;
}

static int cmd_uptime(int argc, char **argv)
{
    (void)argc; (void)argv;
    int64_t s = esp_timer_get_time() / 1000000;
    printf("  up %lld d %02lld:%02lld:%02lld\n", (long long)(s / 86400),
           (long long)(s / 3600 % 24), (long long)(s / 60 % 60), (long long)(s % 60));
    return 0;
}

static int cmd_df(int argc, char **argv)
{
    (void)argc; (void)argv;
    uint64_t total = 0, free_bytes = 0;
    if (!storage_mounted() || esp_vfs_fat_info(STORAGE_ROOT, &total, &free_bytes) != ESP_OK) {
        printf("df: no storage\n");
        return 1;
    }
    printf("  %s   %llu of %llu bytes free (%llu%% used)\n", STORAGE_ROOT,
           (unsigned long long)free_bytes, (unsigned long long)total,
           (unsigned long long)(total ? 100 * (total - free_bytes) / total : 0));
    return 0;
}

static int cmd_log(int argc, char **argv)
{
    static const char *const names[] = { "none", "error", "warn", "info", "debug", "verbose" };
    if (argc == 3)
        for (int l = 0; l < 6; l++)
            if (strcmp(argv[2], names[l]) == 0) {
                esp_log_level_set(argv[1], (esp_log_level_t)l);
                printf("  %s: %s\n", argv[1], names[l]);
                return 0;
            }
    printf("usage: log <tag|*> <none|error|warn|info|debug|verbose>\n");
    return 1;
}

static void complete_log(int argi, const char *prefix, void (*add)(const char *))
{
    static const char *const names[] = { "none", "error", "warn", "info", "debug", "verbose" };
    if (argi == 2)
        for (int l = 0; l < 6; l++)
            if (strncmp(names[l], prefix, strlen(prefix)) == 0)
                add(names[l]);
}

static int cmd_reboot(int argc, char **argv)
{
    (void)argc; (void)argv;
    printf("rebooting\n");
    vTaskDelay(pdMS_TO_TICKS(100));       // let the line reach the terminal
    esp_restart();
    return 0;
}

static const console_cmd_t s_commands[] = {
    { "info",   "",             "firmware, chip, MAC and reset reason",       cmd_info,   NULL },
    { "mem",    "",             "heap: free, lowest ever, largest block",     cmd_mem,    NULL },
    { "tasks",  "",             "FreeRTOS tasks: state, priority, stack, CPU", cmd_tasks, NULL },
    { "uptime", "",             "time since boot",                            cmd_uptime, NULL },
    { "df",     "",             "storage space",                              cmd_df,     NULL },
    { "log",    "<tag> <level>", "set a log level (* for all tags)",          cmd_log,    complete_log },
    { "reboot", "",             "restart the ESP32",                          cmd_reboot, NULL },
};

void cli_system_init(void)
{
    for (size_t i = 0; i < sizeof s_commands / sizeof s_commands[0]; i++)
        console_register(&s_commands[i]);
}
