// ble_midi.c — MIDI over Bluetooth LE (peripheral)
//
// Implements MIDI 1.0 over BLE (the MMA / Bluetooth SIG service):
// primary service 03B80E5A-EDE8-4B33-A751-6CE34EC4C700 carrying one
// "MIDI data I/O" characteristic 7772E5DB-3868-4112-A1A9-F2669D106BF3
// (read, write, write-without-response, notify). Centrals with BLE
// MIDI support — macOS Audio MIDI Setup, Android 13+, iOS — discover
// "Noaidi" and treat it like any wired MIDI port.
//
// Packet format: two header bytes holding a 13-bit millisecond
// timestamp; bit 7 of the second header byte set means a status byte
// follows (running status restarts), clear means the payload
// continues under running status. Timestamps are consumed and
// discarded — this synth has no event scheduling, everything sounds
// on arrival. The payload bytes run through the shared midi_parser,
// which already understands running status and the Note-On-vel-0
// convention.
//
// Threading: all parsing and publishing happen in the NimBLE host
// task via the GATT access callback, so the parser instance is
// single-threaded by construction. event_bus_publish is
// non-blocking, so a slow consumer can never stall the BLE stack.
// On connect and on disconnect the parser resets: running status
// dies with the connection per spec.

#include "ble_midi.h"

#include <string.h>

#include "esp_log.h"
#include "host/ble_hs.h"
#include "host/util/util.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

#include "event_bus.h"
#include "midi_parser.h"

#define TAG "ble_midi"

// Standard MIDI 1.0 over BLE service (03B80E5A-EDE8-4B33-A751-6CE34EC4C700)
// and its MIDI data I/O characteristic (7772E5DB-3868-4112-A1A9-F2669D106BF3).
// BLE_UUID128_INIT takes the bytes in on-air (little-endian) order, i.e.
// the printed UUID reversed.
#define MIDI_SVC_UUID BLE_UUID128_INIT(0x00, 0xC7, 0xC4, 0x4E, 0xE3, 0x6C, 0x51, 0xA7, \
                                       0x33, 0x4B, 0xE8, 0xED, 0x5A, 0x0E, 0xB8, 0x03)
#define MIDI_IO_UUID BLE_UUID128_INIT(0xF3, 0x6B, 0x10, 0x9D, 0x66, 0xF2, 0xA9, 0xA1, \
                                      0x12, 0x41, 0x68, 0x38, 0xDB, 0xE5, 0x72, 0x77)

// Largest possible packet: the negotiated ATT MTU (we prefer 517).
#define BLE_MIDI_MAX_PKT 517

static const ble_uuid128_t gatt_svr_svc_midi_uuid = MIDI_SVC_UUID;
static const ble_uuid128_t gatt_svr_chr_midi_io_uuid = MIDI_IO_UUID;
static uint16_t gatt_svr_chr_midi_io_handle;

// Advertising is one-shot: the stack stops it when a connection
// forms, and the GAP callback restarts it on failure/disconnect.
static bool s_advertising;
static int s_conn_count;

static midi_parser_t g_ble_parser;

// ── Parser callback ────────────────────────────────────────────────
// Runs in the context of the NimBLE host task. Fan-out to consumers
// happens through the event bus (non-blocking).
static void ble_msg_to_bus(const midi_message_t *m, void *user)
{
    evt_t evt = {
        .kind = EVT_MIDI,
        .midi = *m,
    };
    event_bus_publish(&evt);
}

// ── GATT access callback ───────────────────────────────────────────
// Writes carry one BLE MIDI packet (possibly several MIDI messages
// under running status). Parse and publish here; never block.
static int gatt_svr_chr_access(uint16_t conn_handle, uint16_t attr_handle,
                               struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    if (ctxt->op != BLE_GATT_ACCESS_OP_WRITE_CHR) {
        return 0; // reads (and CCCD bookkeeping) pass through
    }

    struct os_mbuf *om = ctxt->om;
    uint16_t n = OS_MBUF_PKTLEN(om);
    if (n < 2) {
        return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN; // no header at all
    }

    uint8_t pkt[BLE_MIDI_MAX_PKT];
    if (n > sizeof(pkt)) {
        return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN; // beyond negotiated MTU
    }
    os_mbuf_copydata(om, 0, n, pkt);

    // Header: 13-bit timestamp in two bytes. Bit 7 of the second byte
    // set = timestamp present and a status byte follows; clear =
    // running status continues.
    int idx = 2;
    if (pkt[1] & 0x80) {
        if (idx >= n) {
            return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN; // status promised, absent
        }
        midi_parser_feed(&g_ble_parser, pkt[idx++]);
    }
    while (idx < n) {
        midi_parser_feed(&g_ble_parser, pkt[idx++]);
    }
    return 0;
}

static const struct ble_gatt_chr_def gatt_svr_chrs[] = {
    {
        .uuid = &gatt_svr_chr_midi_io_uuid.u,
        .access_cb = gatt_svr_chr_access,
        .flags = BLE_GATT_CHR_F_READ |
                 BLE_GATT_CHR_F_WRITE |
                 BLE_GATT_CHR_F_WRITE_NO_RSP |
                 BLE_GATT_CHR_F_NOTIFY,
        .val_handle = &gatt_svr_chr_midi_io_handle,
        .descriptors = (struct ble_gatt_dsc_def[]) {
            {
                .uuid = BLE_UUID16_DECLARE(BLE_GATT_DSC_CLT_CFG_UUID16),
                .att_flags = BLE_ATT_F_READ | BLE_ATT_F_WRITE,
                .access_cb = gatt_svr_chr_access,
            },
            { 0, }
        },
    },
    { 0, }
};

static const struct ble_gatt_svc_def gatt_svr_svcs[] = {
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &gatt_svr_svc_midi_uuid.u,
        .characteristics = gatt_svr_chrs,
    },
    { 0, }
};

// ── Advertising ────────────────────────────────────────────────────

static int ble_midi_gap_event(struct ble_gap_event *event, void *arg);

static void ble_midi_advertise(void)
{
    struct ble_gap_adv_params adv_params;
    struct ble_hs_adv_fields fields;
    int rc;

    memset(&fields, 0, sizeof fields);
    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    fields.name = (uint8_t *)"Noaidi";
    fields.name_len = strlen("Noaidi");
    fields.name_is_complete = 1;
    fields.uuids128 = (ble_uuid128_t *)&gatt_svr_svc_midi_uuid;
    fields.num_uuids128 = 1;
    fields.uuids128_is_complete = 1;

    rc = ble_gap_adv_set_fields(&fields);
    if (rc != 0) {
        ESP_LOGE(TAG, "adv fields: rc=%d", rc);
        return;
    }

    memset(&adv_params, 0, sizeof adv_params);
    adv_params.conn_mode = BLE_GAP_CONN_MODE_UND;
    adv_params.disc_mode = BLE_GAP_DISC_MODE_GEN;
    rc = ble_gap_adv_start(BLE_OWN_ADDR_PUBLIC, NULL, BLE_HS_FOREVER,
                           &adv_params, ble_midi_gap_event, NULL);
    if (rc != 0) {
        ESP_LOGE(TAG, "adv start: rc=%d", rc);
        return;
    }
    s_advertising = true;
}

static int ble_midi_gap_event(struct ble_gap_event *event, void *arg)
{
    switch (event->type) {
    case BLE_GAP_EVENT_CONNECT:
        midi_parser_reset(&g_ble_parser);
        s_advertising = false;
        if (event->connect.status != 0) {
            ESP_LOGW(TAG, "connect failed, re-advertising");
            ble_midi_advertise();
        } else {
            s_conn_count++;
            ESP_LOGI(TAG, "MIDI connection established");
        }
        return 0;

    case BLE_GAP_EVENT_DISCONNECT:
        midi_parser_reset(&g_ble_parser);
        if (s_conn_count > 0) {
            s_conn_count--;
        }
        ESP_LOGI(TAG, "disconnected (reason=%d), advertising",
                 event->disconnect.reason);
        ble_midi_advertise();
        return 0;

    default:
        return 0;
    }
}

// ── Host lifecycle ─────────────────────────────────────────────────

static void ble_midi_on_sync(void)
{
    int rc = ble_hs_util_ensure_addr(0);
    if (rc != 0) {
        ESP_LOGW(TAG, "public address unavailable (rc=%d), falling back to random", rc);
        rc = ble_hs_util_ensure_addr(1);
        if (rc != 0) {
            ESP_LOGE(TAG, "no usable address (rc=%d) - not advertising", rc);
            return;
        }
    }
    ble_midi_advertise();
}

static void ble_midi_host_task(void *param)
{
    nimble_port_run(); // blocks for the life of the stack
    nimble_port_freertos_deinit();
}

// Console key 'p': print stack state and re-trigger advertising.
// NimBLE APIs are safe to call from any task (they queue to the host
// task), so this can run in the shared serial-console dispatcher.
void ble_midi_console_status(void)
{
    bool synced = ble_hs_is_enabled();
    ESP_LOGI(TAG, "BLE: host %s, advertising=%s, connections=%d",
             synced ? "synced" : "NOT synced",
             s_advertising ? "yes" : "no",
             s_conn_count);
    if (synced && !s_advertising) {
        ble_midi_advertise();
    }
}

void ble_midi_init(void)
{
    midi_parser_init(&g_ble_parser, ble_msg_to_bus, NULL);

    // nimble_port_init() is the full bring-up: controller enable, HCI,
    // and the NPL primitives (mutex, event queue) the host lock needs.
    // It MUST run before any service registration - ble_gatts_add_svcs
    // takes ble_hs_lock, and without this call the lock's mutex does
    // not exist yet (load access fault in xQueueSemaphoreTake, seen on
    // silicon). The bundled bleprph example calls it in app_main for
    // exactly this reason; nimble_port_freertos_init() below only
    // spawns the host task.
    ESP_ERROR_CHECK(nimble_port_init());

    // Order matters: the GAP/GATT services must exist before their
    // settings are touched (the bundled bleprph example does exactly
    // this sequence).
    ble_svc_gap_init();
    ble_svc_gatt_init();

    ble_gatts_count_cfg(gatt_svr_svcs);
    ble_gatts_add_svcs(gatt_svr_svcs);

    ble_svc_gap_device_name_set("Noaidi");

    ble_hs_cfg.reset_cb = NULL;   // no bonding, nothing to restore
    ble_hs_cfg.sync_cb = ble_midi_on_sync;

    // nimble_port_freertos_init() in this IDF version wraps
    // esp_nimble_enable(): controller + host bring-up inside, void
    // return - errors surface as abort/log from the stack.
    nimble_port_freertos_init(ble_midi_host_task);

    ESP_LOGI(TAG, "BLE MIDI peripheral up, advertising as \"Noaidi\"");
}
