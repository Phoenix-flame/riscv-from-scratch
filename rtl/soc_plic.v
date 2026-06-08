// =====================================================================
// soc_plic.v  -  SoC demonstrating a PLIC multiplexing several IRQ lines
// ---------------------------------------------------------------------
// cpu_mc (RV32IM) + block RAM + uart_full + plic + syscon. Four interrupt
// sources feed the PLIC, whose single output drives the core's machine
// external interrupt (ext_irq / MEIP):
//
//   source 1 : UART (real peripheral, level-sensitive)
//   source 2 : external line irq_ext[1]
//   source 3 : external line irq_ext[2]
//   source 4 : external line irq_ext[3]
//
//   0x0000_0000  RAM
//   0x1000_0000  UART   (+0 TXDATA +4 RXDATA +8 STATUS +C CONFIG +10 IEN ...)
//   0x1002_0000  PLIC   (priority / pending / enable / threshold / claim)
//   0x2000_0000  SYSCON (write -> halt + LED)
// =====================================================================
`default_nettype none

module soc_plic #(
    parameter ROM_WORDS = 4096,
    parameter RAM_WORDS = 4096,
    parameter IMEM_INIT = "",
    parameter DMEM_INIT = "",
    parameter DEF_CLKS  = 1085
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       uart_rx_pin,
    output wire       uart_tx_pin,
    input  wire [3:1] irq_ext,          // three external peripheral lines
    output wire       halted
);
    wire [31:0] iaddr, irdata, daddr, dwdata, drdata;
    wire [3:0]  dwe;
    wire        dre;
    wire        halt_q, uart_irq, plic_meip;

    cpu_mc u_core (
        .clk(clk), .rst(rst), .timer_irq(1'b0), .ext_irq(plic_meip), .halt(halt_q),
        .imem_addr(iaddr), .imem_rdata(irdata),
        .dmem_addr(daddr), .dmem_we(dwe), .dmem_re(dre),
        .dmem_wdata(dwdata), .dmem_rdata(drdata),
        .pc_out()
    );
    bram_rom #(.WORDS(ROM_WORDS), .INIT_FILE(IMEM_INIT)) u_rom (
        .clk(clk), .addr_word(iaddr[$clog2(ROM_WORDS)+1:2]), .rdata(irdata)
    );

    wire wr_any   = |dwe;
    wire dvalid   = dre | wr_any;                       // a genuine load or store
    wire sel_ram  = (daddr[31:28] == 4'h0);
    wire sel_io   = dvalid & (daddr[31:28] == 4'h1);    // peripherals: real access only
    wire sel_uart = sel_io & (daddr[17:16] == 2'b00);   // 0x1000_xxxx
    wire sel_plic = sel_io & (daddr[17:16] == 2'b10);   // 0x1002_xxxx
    wire sel_sys  = dvalid & (daddr[31:28] == 4'h2);

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

    // four sources into the PLIC: {ext3, ext2, ext1, uart}
    wire [4:1] plic_src = {irq_ext[3], irq_ext[2], irq_ext[1], uart_irq};
    wire [31:0] plic_rdata;
    plic #(.SOURCES(4), .PW(3)) u_plic (
        .clk(clk), .rst(rst),
        .sel(sel_plic), .we(sel_plic & wr_any),
        .addr(daddr[15:0]), .wdata(dwdata), .rdata(plic_rdata),
        .src(plic_src), .meip(plic_meip)
    );

    reg halt_r;
    always @(posedge clk) begin
        if (rst)                   halt_r <= 1'b0;
        else if (sel_sys & wr_any) halt_r <= 1'b1;
    end
    assign halt_q = halt_r; assign halted = halt_r;

    assign drdata = sel_uart ? uart_rdata :
                    sel_plic ? plic_rdata : ram_rdata;
endmodule

`default_nettype wire
