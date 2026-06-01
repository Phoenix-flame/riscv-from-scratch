// =====================================================================
// fpga_top.v  -  Synthesizable top-level for an FPGA (e.g. Zynq-7010 PL)
// ---------------------------------------------------------------------
// The hardware counterpart of soc.v. Differences from the sim SoC:
//   * real UART transmitter (uart_hw) driving a physical pin, not $write
//   * no syscon $finish; a halt just latches a "done" LED
//   * a real clock and an active-low reset button
//   * the program + data are baked into block RAM via $readmemh INIT
//     (synthesizable in Vivado), so no testbench loads them at runtime
//
// Set CLK_FREQ_HZ to your board's PL clock and BAUD to taste; the UART
// bit period is CLK_FREQ_HZ / BAUD cycles.
// =====================================================================
`default_nettype none

module fpga_top #(
    parameter CLK_FREQ_HZ = 50_000_000,
    parameter BAUD        = 115200,
    parameter INIT_FILE   = "sw/socdemo.hex",
    parameter DATA_INIT   = "sw/socdemo_data.hex"
) (
    input  wire       clk,        // PL clock
    input  wire       rstn,       // active-low reset (button)
    output wire       uart_tx,    // serial line to a USB-UART / PMOD
    output reg  [3:0] led         // led[0] = program done
);
    localparam CLKS_PER_BIT = CLK_FREQ_HZ / BAUD;

    // Simple reset synchronizer (active-high internal reset).
    reg [1:0] rst_sync;
    always @(posedge clk) rst_sync <= {rst_sync[0], ~rstn};
    wire rst = rst_sync[1];

    // ---- CPU data bus ----
    wire [31:0] daddr, dwdata, drdata;
    wire        dwe;
    wire [2:0]  dfunct3;
    wire [31:0] pc, instr;
    wire        timer_irq;

    cpu_core #(.INIT_FILE(INIT_FILE)) u_core (
        .clk(clk), .rst(rst), .timer_irq(timer_irq),
        .pc_out(pc), .instr_out(instr),
        .dmem_addr(daddr), .dmem_wdata(dwdata), .dmem_we(dwe),
        .dmem_funct3(dfunct3), .dmem_rdata(drdata)
    );

    // ---- Address decode (same map as soc.v) ----
    wire sel_ram   = (daddr[31:28] == 4'h0);
    wire sel_uart  = (daddr[31:28] == 4'h1) && (daddr[16] == 1'b0);
    wire sel_timer = (daddr[31:28] == 4'h1) && (daddr[16] == 1'b1);
    wire sel_sys   = (daddr[31:28] == 4'h2);

    // ---- RAM (data + preloaded .rodata/.data) ----
    wire [31:0] ram_rdata;
    dmem #(.BYTES(4096), .INIT_FILE(DATA_INIT)) u_ram (
        .clk(clk), .we(dwe && sel_ram),
        .addr(daddr), .wdata(dwdata), .funct3(dfunct3), .rdata(ram_rdata)
    );

    // ---- Real UART ----
    wire [31:0] uart_rdata;
    uart_hw #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_uart (
        .clk(clk), .rst(rst), .sel(sel_uart), .we(dwe && sel_uart),
        .addr(daddr[7:0]), .wdata(dwdata), .rdata(uart_rdata), .tx(uart_tx)
    );

    // ---- Timer ----
    wire [31:0] timer_rdata;
    timer u_timer (
        .clk(clk), .rst(rst), .sel(sel_timer), .we(dwe && sel_timer),
        .addr(daddr[7:0]), .wdata(dwdata), .rdata(timer_rdata), .irq(timer_irq)
    );

    // ---- "syscon" halt: no $finish in hardware; light an LED instead ----
    always @(posedge clk) begin
        if (rst) led <= 4'b0000;
        else if (dwe && sel_sys) led <= 4'b0001 | (dwdata[2:0] << 1);
    end

    // ---- Read mux ----
    assign drdata = sel_uart  ? uart_rdata  :
                    sel_timer ? timer_rdata :
                                ram_rdata;
endmodule

`default_nettype wire
