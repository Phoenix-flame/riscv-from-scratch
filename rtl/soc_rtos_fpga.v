// =====================================================================
// soc_rtos_fpga.v  -  Synthesizable FreeRTOS SoC for the Zynq-7010 PL
// ---------------------------------------------------------------------
// The synthesizable sibling of soc_rtos: the multi-cycle BRAM core
// (cpu_mc, RV32IM + CSR + traps, no $-tasks), real UART, a synthesizable
// halt/LED register, and the 64-bit CLINT machine timer FreeRTOS needs.
// Both block RAMs are initialised from the same FreeRTOS image word-hex
// (data RAM holds a copy of .text plus the correct .rodata/.data; .bss /
// heap / stack are zero and set up at boot).
//
//   0x0000_0000  RAM    (block RAM)
//   0x1000_0000  UART   (+0 TX, +4 STATUS)
//   0x1001_0000  CLINT  (+0/+4 MTIME, +8/+C MTIMECMP)
//   0x2000_0000  SYSCON (write -> halt + LED)
// =====================================================================
`default_nettype none

module soc_rtos_fpga #(
    parameter ROM_WORDS    = 16384,         // 64 KB instruction ROM
    parameter RAM_WORDS    = 16384,         // 64 KB data RAM
    parameter IMEM_INIT    = "",
    parameter DMEM_INIT    = "",
    parameter CLKS_PER_BIT = 1085           // 125 MHz / 115200 baud
) (
    input  wire clk,
    input  wire rst,
    output wire uart_tx_pin,
    output wire halted
);
    wire [31:0] iaddr, irdata;
    wire [31:0] daddr, dwdata, drdata;
    wire [3:0]  dwe;
    wire        timer_irq, halt_q;

    cpu_mc u_core (
        .clk(clk), .rst(rst), .timer_irq(timer_irq), .halt(halt_q),
        .imem_addr(iaddr), .imem_rdata(irdata),
        .dmem_addr(daddr), .dmem_we(dwe), .dmem_wdata(dwdata), .dmem_rdata(drdata),
        .pc_out()
    );

    bram_rom #(.WORDS(ROM_WORDS), .INIT_FILE(IMEM_INIT)) u_rom (
        .clk(clk), .addr_word(iaddr[$clog2(ROM_WORDS)+1:2]), .rdata(irdata)
    );

    wire sel_ram   = (daddr[31:28] == 4'h0);
    wire sel_uart  = (daddr[31:28] == 4'h1) && (daddr[16] == 1'b0);
    wire sel_clint = (daddr[31:28] == 4'h1) && (daddr[16] == 1'b1);
    wire sel_sys   = (daddr[31:28] == 4'h2);
    wire           wr_any = |dwe;

    wire [31:0] ram_rdata;
    bram_ram #(.WORDS(RAM_WORDS), .INIT_FILE(DMEM_INIT)) u_ram (
        .clk(clk), .addr_word(daddr[$clog2(RAM_WORDS)+1:2]),
        .we(sel_ram ? dwe : 4'b0000), .wdata(dwdata), .rdata(ram_rdata)
    );

    wire [31:0] uart_rdata;
    uart_hw #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_uart (
        .clk(clk), .rst(rst), .sel(sel_uart), .we(sel_uart & wr_any),
        .addr(daddr[7:0]), .wdata(dwdata), .rdata(uart_rdata), .tx(uart_tx_pin)
    );

    // ---- 64-bit CLINT machine timer ----
    wire [31:0] clint_rdata;
    clint u_clint (
        .clk(clk), .rst(rst), .sel(sel_clint), .we(sel_clint & wr_any),
        .addr(daddr[7:0]), .wdata(dwdata), .rdata(clint_rdata), .irq(timer_irq)
    );

    // ---- SYSCON halt register (lights the LED, freezes the CPU) ----
    reg halt_r;
    always @(posedge clk) begin
        if (rst)                   halt_r <= 1'b0;
        else if (sel_sys & wr_any) halt_r <= 1'b1;
    end
    assign halt_q = halt_r;
    assign halted = halt_r;

    assign drdata = sel_uart  ? uart_rdata  :
                    sel_clint ? clint_rdata :
                                ram_rdata;
endmodule

`default_nettype wire
