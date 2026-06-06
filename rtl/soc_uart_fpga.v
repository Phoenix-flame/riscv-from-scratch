// =====================================================================
// soc_uart_fpga.v  -  Synthesizable SoC with the configurable UART
// ---------------------------------------------------------------------
// Multi-cycle BRAM core (cpu_mc, RV32IM) + block RAM + uart_full (TX+RX,
// runtime-configurable baud/data-bits/parity/stop) + syscon-halt. Built
// for the Zynq-7010 PL. Software configures the UART via its CONFIG
// register and can both send and receive.
//
//   0x0000_0000  RAM    (block RAM, holds code+data image)
//   0x1000_0000  UART   (+0 TXDATA, +4 RXDATA, +8 STATUS, +C CONFIG)
//   0x2000_0000  SYSCON (write -> halt + LED)
// =====================================================================
`default_nettype none

module soc_uart_fpga #(
    parameter ROM_WORDS = 4096,
    parameter RAM_WORDS = 4096,
    parameter IMEM_INIT = "",
    parameter DMEM_INIT = "",
    parameter DEF_CLKS  = 1085          // reset default baud divisor (115200@125MHz)
) (
    input  wire clk,
    input  wire rst,
    input  wire uart_rx_pin,
    output wire uart_tx_pin,
    output wire halted
);
    wire [31:0] iaddr, irdata, daddr, dwdata, drdata;
    wire [3:0]  dwe;
    wire        halt_q, uart_irq;

    cpu_mc u_core (
        .clk(clk), .rst(rst), .timer_irq(1'b0), .ext_irq(uart_irq), .halt(halt_q),
        .imem_addr(iaddr), .imem_rdata(irdata),
        .dmem_addr(daddr), .dmem_we(dwe), .dmem_wdata(dwdata), .dmem_rdata(drdata),
        .pc_out()
    );
    bram_rom #(.WORDS(ROM_WORDS), .INIT_FILE(IMEM_INIT)) u_rom (
        .clk(clk), .addr_word(iaddr[$clog2(ROM_WORDS)+1:2]), .rdata(irdata)
    );

    wire sel_ram  = (daddr[31:28] == 4'h0);
    wire sel_uart = (daddr[31:28] == 4'h1);
    wire sel_sys  = (daddr[31:28] == 4'h2);
    wire wr_any   = |dwe;

    wire [31:0] ram_rdata;
    bram_ram #(.WORDS(RAM_WORDS), .INIT_FILE(DMEM_INIT)) u_ram (
        .clk(clk), .addr_word(daddr[$clog2(RAM_WORDS)+1:2]),
        .we(sel_ram ? dwe : 4'b0), .wdata(dwdata), .rdata(ram_rdata)
    );

    wire [31:0] uart_rdata;
    uart_full #(.DEF_CLKS(DEF_CLKS)) u_uart (
        .clk(clk), .rst(rst), .sel(sel_uart), .we(sel_uart & wr_any),
        .addr(daddr[7:0]), .wdata(dwdata), .rdata(uart_rdata),
        .rx(uart_rx_pin), .tx(uart_tx_pin), .irq(uart_irq)
    );

    reg halt_r;
    always @(posedge clk) begin
        if (rst)                   halt_r <= 1'b0;
        else if (sel_sys & wr_any) halt_r <= 1'b1;
    end
    assign halt_q = halt_r; assign halted = halt_r;
    assign drdata = sel_uart ? uart_rdata : ram_rdata;
endmodule

`default_nettype wire
