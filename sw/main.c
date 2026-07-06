// ================================================================================ //
// Tang Nano 20K Synthesizer — NEORV32 Application Firmware
//
// UART0: Console interface (19200 baud) — debug output, configuration
// UART1: MIDI input (31250 baud) — receives MIDI from external keyboard
//
// Currently: echo test — MIDI bytes received on UART1 are printed to UART0.
// Future: MIDI parser, voice allocator, coefficient engine, patch management.
// ================================================================================ //

#include <neorv32.h>

//--------------------------------------------------------------------
// Configuration
//--------------------------------------------------------------------
#define CONSOLE_BAUD  19200
#define MIDI_BAUD     31250

//--------------------------------------------------------------------
// Main
//--------------------------------------------------------------------
int main() {

    // Capture exceptions with debug info via UART
    neorv32_rte_setup();

    // Setup UART0 as console
    neorv32_uart0_setup(CONSOLE_BAUD, 0);

    // Setup UART1 for MIDI input (RX only, no interrupts initially)
    neorv32_uart1_setup(MIDI_BAUD, 0);

    // Print banner
    neorv32_uart0_puts("\n========================================\n");
    neorv32_uart0_puts(" Tang Nano 20K — Polyphonic Synthesizer\n");
    neorv32_uart0_puts("========================================\n");
    neorv32_uart0_puts("UART0 (console): 19200 baud\n");
    neorv32_uart0_puts("UART1 (MIDI in): 31250 baud\n");
    neorv32_uart0_puts("\nReady. Waiting for MIDI...\n\n");

    // Main loop: echo MIDI bytes to console
    while (1) {
        // Check if a byte is available on UART1 (MIDI)
        if (neorv32_uart1_char_received()) {
            char midi_byte = neorv32_uart1_getc();
            neorv32_uart0_printf("MIDI: 0x%02x\n", (uint8_t)midi_byte);
        }

        // Check console for commands
        if (neorv32_uart0_char_received()) {
            char cmd = neorv32_uart0_getc();

            switch (cmd) {
                case '?':
                case 'h':
                    neorv32_uart0_puts("Commands:\n");
                    neorv32_uart0_puts("  h / ?  — this help\n");
                    neorv32_uart0_puts("  i      — system info\n");
                    break;

                case 'i':
                    neorv32_uart0_puts("System clock: 98.304 MHz (MS5351)\n");
                    neorv32_uart0_puts("IMEM: 16 KB, DMEM: 8 KB\n");
                    neorv32_uart0_puts("UART0: console, UART1: MIDI\n");
                    break;

                default:
                    neorv32_uart0_puts("Unknown command. 'h' for help.\n");
                    break;
            }
        }
    }

    return 0;
}
