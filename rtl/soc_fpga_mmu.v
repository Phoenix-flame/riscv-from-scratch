// =====================================================================
// soc_fpga.v  -  Synthesizable SoC: multi-cycle core + BRAM + real UART
// ---------------------------------------------------------------------
// Fully synthesizable (no $write/$finish). Instruction ROM and data RAM
// are block RAMs (registered reads); the UART is the real serializer
// (uart_hw -> uart_tx); SYSCON is a halt register that lights an LED and
// freezes the CPU instead of calling $finish.
//
//   0x0000_0000  RAM   (block RAM)
//   0x1000_0000  UART  (+0 TX, +4 STATUS)
//   0x1001_0000  TIMER (+0 MTIME, +4 MTIMECMP)
//   0x2000_0000  SYSCON (write -> halt)
// =====================================================================
`default_nettype none

module soc_fpga_mmu #(
    parameter ROM_WORDS    = 1024,
    parameter RAM_WORDS    = 4096,
    parameter IMEM_INIT    = "",
    parameter DMEM_INIT    = "",
    parameter CLKS_PER_BIT = 1085           // 125 MHz / 115200 baud
) (
    input  wire clk,
    input  wire rst,
    output wire uart_tx_pin,
    output wire halted
);
    // ---- CPU <-> memory/bus wires ----
    wire [31:0] iaddr, irdata;
    wire [31:0] daddr, dwdata, drdata;
    wire [3:0]  dwe;
    wire        timer_irq;
    wire        halt_q;

    cpu_mc_mmu u_core (
        .clk(clk), .rst(rst), .timer_irq(timer_irq), .halt(halt_q),
        .imem_addr(iaddr), .imem_rdata(irdata),
        .dmem_addr(daddr), .dmem_we(dwe), .dmem_wdata(dwdata), .dmem_rdata(drdata),
        .pc_out()
    );

    // ---- instruction ROM (block RAM, registered read) ----
    bram_rom #(.WORDS(ROM_WORDS), .INIT_FILE(IMEM_INIT)) u_rom (
        .clk(clk), .addr_word(iaddr[$clog2(ROM_WORDS)+1:2]), .rdata(irdata)
    );

    // ---- address decode (on the physical/data address) ----
    wire sel_ram   = (daddr[31:28] == 4'h0);
    wire sel_uart  = (daddr[31:28] == 4'h1) && (daddr[16] == 1'b0);
    wire sel_timer = (daddr[31:28] == 4'h1) && (daddr[16] == 1'b1);
    wire sel_sys   = (daddr[31:28] == 4'h2);
    wire           wr_any = |dwe;

    // ---- data RAM (block RAM, byte-write, registered read) ----
    wire [31:0] ram_rdata;
    bram_ram #(.WORDS(RAM_WORDS), .INIT_FILE(DMEM_INIT)) u_ram (
        .clk(clk), .addr_word(daddr[$clog2(RAM_WORDS)+1:2]),
        .we(sel_ram ? dwe : 4'b0000), .wdata(dwdata), .rdata(ram_rdata)
    );

    // ---- UART (real serializer) ----
    wire [31:0] uart_rdata;
    uart_hw #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_uart (
        .clk(clk), .rst(rst), .sel(sel_uart), .we(sel_uart & wr_any),
        .addr(daddr[7:0]), .wdata(dwdata), .rdata(uart_rdata), .tx(uart_tx_pin)
    );

    // ---- TIMER ----
    wire [31:0] timer_rdata;
    timer u_timer (
        .clk(clk), .rst(rst), .sel(sel_timer), .we(sel_timer & wr_any),
        .addr(daddr[7:0]), .wdata(dwdata), .rdata(timer_rdata), .irq(timer_irq)
    );

    // ---- SYSCON: a write halts the CPU and lights the LED ----
    reg halt_r;
    always @(posedge clk) begin
        if (rst)                       halt_r <= 1'b0;
        else if (sel_sys & wr_any)     halt_r <= 1'b1;
    end
    assign halt_q = halt_r;
    assign halted = halt_r;

    assign drdata = sel_uart  ? uart_rdata  :
                    sel_timer ? timer_rdata :
                                ram_rdata;
endmodule

`default_nettype wire
