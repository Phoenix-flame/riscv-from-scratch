// soc_pipe.v - same SoC as soc.v but built around the PIPELINED trap core.
`default_nettype none
module soc_pipe #(
    parameter INIT_FILE = "",
    parameter DATA_INIT = ""
) (
    input  wire clk, rst,
    output wire [31:0] pc_out, instr_out
);
    wire [31:0] daddr, dwdata, drdata; wire dwe; wire [2:0] dfunct3;
    wire timer_irq;

    cpu_pipe_trap #(.INIT_FILE(INIT_FILE), .DATA_INIT(DATA_INIT)) u_core (
        .clk(clk), .rst(rst), .timer_irq(timer_irq),
        .pc_out(pc_out), .instr_out(instr_out),
        .dmem_addr(daddr), .dmem_wdata(dwdata), .dmem_we(dwe),
        .dmem_funct3(dfunct3), .dmem_rdata(drdata)
    );

    wire sel_ram   = (daddr[31:28]==4'h0);
    wire sel_uart  = (daddr[31:28]==4'h1) && (daddr[16]==1'b0);
    wire sel_timer = (daddr[31:28]==4'h1) && (daddr[16]==1'b1);
    wire sel_sys   = (daddr[31:28]==4'h2);

    wire [31:0] ram_rdata, uart_rdata, timer_rdata;
    dmem #(.BYTES(4096), .INIT_FILE(DATA_INIT)) u_ram (
        .clk(clk), .we(dwe && sel_ram), .addr(daddr), .wdata(dwdata),
        .funct3(dfunct3), .rdata(ram_rdata));
    uart u_uart (.clk(clk), .sel(sel_uart), .we(dwe && sel_uart),
        .addr(daddr[7:0]), .wdata(dwdata), .rdata(uart_rdata));
    timer u_timer (.clk(clk), .rst(rst), .sel(sel_timer), .we(dwe && sel_timer),
        .addr(daddr[7:0]), .wdata(dwdata), .rdata(timer_rdata), .irq(timer_irq));
    syscon u_syscon (.clk(clk), .sel(sel_sys), .we(dwe && sel_sys), .wdata(dwdata));

    assign drdata = sel_uart ? uart_rdata : sel_timer ? timer_rdata : ram_rdata;
endmodule
`default_nettype wire
