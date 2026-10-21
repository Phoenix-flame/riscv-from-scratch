// =====================================================================
// soc_pipe_u.v  -  the unified pipelined core on IDEAL memory
// ---------------------------------------------------------------------
// cpu_pipe_u with the memory it was designed against: a combinational
// instruction ROM and a combinational, byte-maskable data RAM, both
// always ready. Same peripherals and map as the synthesizable MMU SoCs
// (soc_fpga_mmu / soc_fpga_tlb), so their programs run here unchanged:
//
//   0x0000_0000  RAM    (I-port: ROM; D-port: RAM -- Harvard)
//   0x1000_0000  UART   (+0 TX, +4 STATUS)
//   0x1001_0000  TIMER  (+0 MTIME, +4 MTIMECMP)
//   0x2000_0000  SYSCON (write -> halt)
//
// "Ideal" is the point and the problem: a combinational read of a large
// array is not a block RAM. Step 43 puts caches between this core and
// real (slow) memory; the core does not change.
// =====================================================================
`default_nettype none

module soc_pipe_u #(
    parameter ROM_WORDS    = 4096,
    parameter RAM_WORDS    = 8192,
    parameter IMEM_INIT    = "",
    parameter DMEM_INIT    = "",
    parameter TLB_ENTRIES  = 4,
    parameter CLKS_PER_BIT = 1085
) (
    input  wire clk,
    input  wire rst,
    output wire uart_tx_pin,
    output wire halted
);
    wire [31:0] iaddr, irdata, daddr, dwdata, drdata;
    wire        ireq, dreq;
    wire [3:0]  dwe;
    wire        timer_irq, halt_q, retire;

    cpu_pipe_u #(.TLB_ENTRIES(TLB_ENTRIES)) u_core (
        .clk(clk), .rst(rst), .timer_irq(timer_irq), .halt(halt_q),
        .i_addr(iaddr), .i_req(ireq), .i_rdata(irdata), .i_ready(1'b1),
        .d_addr(daddr), .d_req(dreq), .d_we(dwe), .d_wdata(dwdata),
        .d_rdata(drdata), .d_ready(1'b1),
        .pc_out(), .retire(retire)
    );

    // ---- instruction ROM (combinational) ----
    reg [31:0] rom [0:ROM_WORDS-1];
    reg [31:0] ram [0:RAM_WORDS-1];
    integer k;
    initial begin
        for (k = 0; k < ROM_WORDS; k = k + 1) rom[k] = 32'd0;
        for (k = 0; k < RAM_WORDS; k = k + 1) ram[k] = 32'd0;
        if (IMEM_INIT != "") $readmemh(IMEM_INIT, rom);
        if (DMEM_INIT != "") $readmemh(DMEM_INIT, ram);
    end
    assign irdata = rom[iaddr[$clog2(ROM_WORDS)+1:2]];

    // ---- address decode (physical) ----
    wire sel_ram   = (daddr[31:28] == 4'h0);
    wire sel_uart  = (daddr[31:28] == 4'h1) && (daddr[16] == 1'b0);
    wire sel_timer = (daddr[31:28] == 4'h1) && (daddr[16] == 1'b1);
    wire sel_sys   = (daddr[31:28] == 4'h2);
    wire wr_any    = dreq & (|dwe);

    // ---- data RAM (combinational read, byte-lane write) ----
    wire [$clog2(RAM_WORDS)-1:0] rw = daddr[$clog2(RAM_WORDS)+1:2];
    wire [31:0] ram_rdata = ram[rw];
    always @(posedge clk)
        if (dreq && sel_ram) begin
            if (dwe[0]) ram[rw][7:0]   <= dwdata[7:0];
            if (dwe[1]) ram[rw][15:8]  <= dwdata[15:8];
            if (dwe[2]) ram[rw][23:16] <= dwdata[23:16];
            if (dwe[3]) ram[rw][31:24] <= dwdata[31:24];
        end

    wire [31:0] uart_rdata, timer_rdata;
    uart_hw #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_uart (
        .clk(clk), .rst(rst), .sel(dreq & sel_uart), .we(sel_uart & wr_any),
        .addr(daddr[7:0]), .wdata(dwdata), .rdata(uart_rdata), .tx(uart_tx_pin)
    );
    timer u_timer (
        .clk(clk), .rst(rst), .sel(dreq & sel_timer), .we(sel_timer & wr_any),
        .addr(daddr[7:0]), .wdata(dwdata), .rdata(timer_rdata), .irq(timer_irq)
    );

    reg halt_r;
    always @(posedge clk)
        if (rst) halt_r <= 1'b0;
        else if (sel_sys & wr_any) halt_r <= 1'b1;
    assign halt_q = halt_r;
    assign halted = halt_r;

    assign drdata = sel_uart  ? uart_rdata  :
                    sel_timer ? timer_rdata : ram_rdata;
endmodule

`default_nettype wire
