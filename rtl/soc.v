// =====================================================================
// soc.v  -  System-on-chip: CPU core + bus + RAM + peripherals
// ---------------------------------------------------------------------
// The address decoder routes each data access to one device by address:
//
//   0x0000_0000 .. 0x0FFF_FFFF   RAM   (4 KB, wraps)
//   0x1000_0000 .. 0x1000_FFFF   UART
//   0x1001_0000 .. 0x1001_FFFF   TIMER
//   0x2000_0000 .. 0x2FFF_FFFF   SYSCON (halt)
//
// Instruction fetch stays inside the core (a ROM loaded from INIT_FILE).
// =====================================================================
`default_nettype none

module soc #(
    parameter INIT_FILE = ""
) (
    input  wire        clk,
    input  wire        rst,
    output wire [31:0] pc_out,
    output wire [31:0] instr_out
);
    // ---- CPU data bus ----------------------------------------------
    wire [31:0] daddr, dwdata, drdata;
    wire        dwe;
    wire [2:0]  dfunct3;

    cpu_core #(.INIT_FILE(INIT_FILE)) u_core (
        .clk(clk), .rst(rst),
        .pc_out(pc_out), .instr_out(instr_out),
        .dmem_addr(daddr), .dmem_wdata(dwdata), .dmem_we(dwe),
        .dmem_funct3(dfunct3), .dmem_rdata(drdata)
    );

    // ---- Address decode: one select line per device ----------------
    wire sel_ram   = (daddr[31:28] == 4'h0);
    wire sel_uart  = (daddr[31:28] == 4'h1) && (daddr[16] == 1'b0);
    wire sel_timer = (daddr[31:28] == 4'h1) && (daddr[16] == 1'b1);
    wire sel_sys   = (daddr[31:28] == 4'h2);

    // ---- RAM (reuse the dmem block as the system RAM) --------------
    wire [31:0] ram_rdata;
    dmem #(.BYTES(4096)) u_ram (
        .clk(clk), .we(dwe && sel_ram),
        .addr(daddr), .wdata(dwdata), .funct3(dfunct3),
        .rdata(ram_rdata)
    );

    // ---- UART ------------------------------------------------------
    wire [31:0] uart_rdata;
    uart u_uart (
        .clk(clk), .sel(sel_uart), .we(dwe && sel_uart),
        .addr(daddr[7:0]), .wdata(dwdata), .rdata(uart_rdata)
    );

    // ---- TIMER -----------------------------------------------------
    wire [31:0] timer_rdata;
    timer u_timer (
        .clk(clk), .rst(rst), .sel(sel_timer), .we(dwe && sel_timer),
        .addr(daddr[7:0]), .wdata(dwdata), .rdata(timer_rdata)
    );

    // ---- SYSCON (halt) ---------------------------------------------
    syscon u_syscon (
        .clk(clk), .sel(sel_sys), .we(dwe && sel_sys), .wdata(dwdata)
    );

    // ---- Read-data mux: return the selected device's data ----------
    assign drdata = sel_uart  ? uart_rdata  :
                    sel_timer ? timer_rdata :
                                ram_rdata;   // default / RAM

endmodule

`default_nettype wire
