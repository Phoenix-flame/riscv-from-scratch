// =====================================================================
// soc_mmu.v  -  SoC built around the Sv32-MMU core.
// ---------------------------------------------------------------------
// Same as soc.v, but the CPU's data address is a *physical* address
// already translated by the MMU inside the core, and the core's two
// page-table-walk read ports are wired to extra read ports on the RAM.
// Page tables therefore live in RAM and are walked by the hardware.
// =====================================================================
`default_nettype none

module soc_mmu #(
    parameter INIT_FILE = "",
    parameter DATA_INIT = ""
) (
    input  wire        clk,
    input  wire        rst,
    output wire [31:0] pc_out,
    output wire [31:0] instr_out
);
    wire [31:0] daddr, dwdata, drdata;
    wire        dwe;
    wire [2:0]  dfunct3;
    wire        timer_irq;
    wire [31:0] walk_a1, walk_d1, walk_a2, walk_d2;

    cpu_core_mmu #(.INIT_FILE(INIT_FILE)) u_core (
        .clk(clk), .rst(rst), .timer_irq(timer_irq),
        .pc_out(pc_out), .instr_out(instr_out),
        .dmem_addr(daddr), .dmem_wdata(dwdata), .dmem_we(dwe),
        .dmem_funct3(dfunct3), .dmem_rdata(drdata),
        .walk_addr1(walk_a1), .walk_data1(walk_d1),
        .walk_addr2(walk_a2), .walk_data2(walk_d2)
    );

    // address decode operates on the PHYSICAL address from the MMU
    wire sel_ram   = (daddr[31:28] == 4'h0);
    wire sel_uart  = (daddr[31:28] == 4'h1) && (daddr[16] == 1'b0);
    wire sel_timer = (daddr[31:28] == 4'h1) && (daddr[16] == 1'b1);
    wire sel_sys   = (daddr[31:28] == 4'h2);

    wire [31:0] ram_rdata;
    dmem #(.BYTES(8192), .INIT_FILE(DATA_INIT)) u_ram (
        .clk(clk), .we(dwe && sel_ram),
        .addr(daddr), .wdata(dwdata), .funct3(dfunct3), .rdata(ram_rdata),
        .walk_addr1(walk_a1), .walk_data1(walk_d1),     // page-walk ports
        .walk_addr2(walk_a2), .walk_data2(walk_d2)
    );

    wire [31:0] uart_rdata;
    uart u_uart (
        .clk(clk), .sel(sel_uart), .we(dwe && sel_uart),
        .addr(daddr[7:0]), .wdata(dwdata), .rdata(uart_rdata)
    );

    wire [31:0] timer_rdata;
    timer u_timer (
        .clk(clk), .rst(rst), .sel(sel_timer), .we(dwe && sel_timer),
        .addr(daddr[7:0]), .wdata(dwdata), .rdata(timer_rdata), .irq(timer_irq)
    );

    syscon u_syscon (
        .clk(clk), .sel(sel_sys), .we(dwe && sel_sys), .wdata(dwdata)
    );

    assign drdata = sel_uart  ? uart_rdata  :
                    sel_timer ? timer_rdata :
                                ram_rdata;
endmodule

`default_nettype wire
