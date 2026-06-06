// =====================================================================
// soc_rtos.v  -  SoC sized & wired for an RTOS (FreeRTOS) on cpu_core
// ---------------------------------------------------------------------
// Same CPU as the rest of the tutorial (RV32IMA + Zicsr + M/U privilege),
// but with memory large enough for a kernel + heap + task stacks, and the
// 64-bit CLINT machine timer the FreeRTOS RISC-V port expects.
//
//   0x0000_0000  RAM    (64 KB)
//   0x1000_0000  UART   (+0 TX, +4 STATUS)
//   0x1001_0000  CLINT  (+0/+4 MTIME, +8/+C MTIMECMP)   <- 64-bit
//   0x2000_0000  SYSCON (write -> halt)
//
//   FreeRTOSConfig.h: configMTIME_BASE_ADDRESS    = 0x10010000
//                     configMTIMECMP_BASE_ADDRESS = 0x10010008
// =====================================================================
`default_nettype none

module soc_rtos #(
    parameter INIT_FILE  = "",
    parameter DATA_INIT  = "",
    parameter IMEM_WORDS = 16384,        // 64 KB instruction ROM
    parameter RAM_BYTES  = 65536         // 64 KB data RAM
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

    cpu_core #(.INIT_FILE(INIT_FILE), .IMEM_WORDS(IMEM_WORDS)) u_core (
        .clk(clk), .rst(rst), .timer_irq(timer_irq),
        .pc_out(pc_out), .instr_out(instr_out),
        .dmem_addr(daddr), .dmem_wdata(dwdata), .dmem_we(dwe),
        .dmem_funct3(dfunct3), .dmem_rdata(drdata)
    );

    wire sel_ram   = (daddr[31:28] == 4'h0);
    wire sel_uart  = (daddr[31:28] == 4'h1) && (daddr[16] == 1'b0);
    wire sel_clint = (daddr[31:28] == 4'h1) && (daddr[16] == 1'b1);
    wire sel_sys   = (daddr[31:28] == 4'h2);

    wire [31:0] ram_rdata;
    dmem #(.BYTES(RAM_BYTES), .INIT_FILE(DATA_INIT)) u_ram (
        .clk(clk), .we(dwe && sel_ram),
        .addr(daddr), .wdata(dwdata), .funct3(dfunct3), .rdata(ram_rdata)
    );

    wire [31:0] uart_rdata;
    uart u_uart (
        .clk(clk), .sel(sel_uart), .we(dwe && sel_uart),
        .addr(daddr[7:0]), .wdata(dwdata), .rdata(uart_rdata)
    );

    wire [31:0] clint_rdata;
    clint u_clint (
        .clk(clk), .rst(rst), .sel(sel_clint), .we(dwe && sel_clint),
        .addr(daddr[7:0]), .wdata(dwdata), .rdata(clint_rdata), .irq(timer_irq)
    );

    syscon u_syscon (.clk(clk), .sel(sel_sys), .we(dwe && sel_sys), .wdata(dwdata));

    assign drdata = sel_uart  ? uart_rdata  :
                    sel_clint ? clint_rdata :
                                ram_rdata;
endmodule

`default_nettype wire
