// Target: SystemVerilog-2017 top level for NEORV32 on Tang Nano 20K
module top (
    input  logic       clk,
    input  logic       rst,
    output logic       uart_tx,
    input  logic       uart_rx,
    output logic [5:0] led
);

    // Remote reset via UART Break condition
    // Detects if the RX line is held low continuously
    reg [24:0] break_timer = 0;
    reg break_rst_n = 1'b1;

    always @(posedge clk) begin
        if (uart_rx == 1'b0) begin
            // 45000 cycles at 27MHz equals ~1.66ms continuous low threshold
            if (break_timer < 'd45000) begin
                break_timer <= break_timer + 1'b1;
                break_rst_n <= 1'b1;
            end else begin
                break_rst_n <= 1'b0; // Assert software reset
            end
        end else begin
            break_timer <= 0;
            break_rst_n <= 1'b1; // Deassert software reset
        end
    end

    // Internal 32-bit bus for GPIO output
    logic [31:0] gpio_o_s;

    // Streamlined LED assignment using vector concatenation
    // led[5:2] = high, led[1] = clk, led[0] = inverted GPIO[0]
    assign led = {4'b1111, ~gpio_o_s[0], break_rst_n};

    // Instantiation of the VHDL NEORV32 processor core
    neorv32_top #(
        .CLOCK_FREQUENCY(27000000),
        .BOOT_MODE_SELECT(0),          // Start with bootloader menu over UART
        .RISCV_ISA_C(1),               // Compressed extension
        .RISCV_ISA_M(1),               // MUL/DIV extension
        .CPU_FAST_MUL_EN(1),           // Use DSPs for M extension's multiplier
        .CPU_FAST_SHIFT_EN(1),         // Use barrel shifter for shift operations
        .IMEM_EN(1),                   // Enable internal instruction memory
        .DMEM_EN(1),                   // Enable internal data memory
        .IO_GPIO_NUM(1),               // 1 GPIO channel enabled
        .IO_GPIO_DIR_EN(1),            // Enable GPIO direction control port 
        .IO_UART0_EN(1)                // Enable UART 0
    ) neorv32_top_inst (
        // Clock and Reset (Expressions allowed directly on inputs)
        .clk_i  (clk),
        .rstn_i (~rst && break_rst_n),
        
        // UART0 external connections
        .uart0_txd_o(uart_tx),
        .uart0_rxd_i(uart_rx),

        // GPIO connections
        .gpio_i ('0),                  // SV fill-with-zeros literal
        .gpio_o (gpio_o_s),

        // Unused subsystem inputs tied to zero using SV '0 literal
        .cfs_in_i       ('0),
        .slink_rx_dat_i ('0),
        .slink_rx_src_i ('0),
        .xbus_dat_i     ('0)
    );

 

endmodule
