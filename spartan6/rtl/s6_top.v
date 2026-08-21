// =====================================================================
// s6_top.v  -  FPGA top level for the Posedge One (XC6SLX9-TQG144)
// ---------------------------------------------------------------------
// Board resources this design uses, all straight from the board's own
// UCF (constraints/posedge_one_lx9.ucf):
//
//   CLOCK      p50    24 MHz oscillator -> PLL -> 16 MHz SoC clock
//   RESET_N    p133   USER_PB, active low, internal pull-up
//   UART_TX    p104   to the FT2232's RX      (FPGA drives)
//   UART_RX    p105   from the FT2232's TX    (FPGA samples)
//   USER_LED   p88    driven from GPIO bit 0
//   SRAM_*            IS61WV5128BLL, 512K x 8 asynchronous SRAM
//   W1_A01..08        GPIO outputs   (gpio_o[7:0])
//   W1_B01..08        GPIO inputs    (gpio_i[7:0])
//
// Note that UART_TX/UART_RX (p104/p105) are the same FPGA pins as the
// FT2232's FT_D1/FT_D0 async-FIFO data lines. Only one of the two
// personalities can be used at a time; this design uses the UART one, so
// the FT2232 channel must be configured as a plain serial port.
//
// The tristate for the SRAM data bus lives here, at the top, which is
// where XST wants to see it in order to infer IOBUFs.
// =====================================================================
`default_nettype none

module s6_top #(
    parameter integer CLK_HZ    = 16_000_000,
    parameter integer BAUD      = 115200,
    parameter integer MEM_WORDS = 4096,
    // $readmemh resolves this relative to the directory synthesis runs in,
    // which for syn/build_ise.sh and syn/build.tcl is spartan6/syn/.
    parameter         MEM_INIT  = "../sw/firmware.hex"
) (
    input  wire        clk_24,
    input  wire        rst_n,

    output wire        uart_tx,
    input  wire        uart_rx,

    output wire        user_led,

    output wire [18:0] sram_addr,
    inout  wire [7:0]  sram_data,
    output wire        sram_we_n,
    output wire        sram_oe_n,
    output wire        sram_ce_n,

    output wire [7:0]  gpio_o,
    input  wire [7:0]  gpio_i
);
    // ---- clock ----
    wire clk, pll_locked;
    s6_clkgen u_clk (.clk_in(clk_24), .clk_out(clk), .locked(pll_locked));

    // ---- reset: synchronise the button, and hold until the PLL locks ----
    reg [1:0]  rst_sync;
    reg [15:0] rst_cnt;
    reg        rst;
    always @(posedge clk) begin
        rst_sync <= {rst_sync[0], ~rst_n | ~pll_locked};
        if (rst_sync[1]) begin
            rst_cnt <= 16'd0;
            rst     <= 1'b1;
        end else if (!(&rst_cnt)) begin
            rst_cnt <= rst_cnt + 16'd1;
            rst     <= 1'b1;
        end else
            rst <= 1'b0;
    end

    // ---- SRAM data bus tristate (IOBUF inference) ----
    wire [7:0] sram_dout, sram_din;
    wire       sram_doe;
    assign sram_data = sram_doe ? sram_dout : 8'bz;
    assign sram_din  = sram_data;

    // ---- the SoC ----
    wire [7:0] gpio_out_w;
    s6_soc #(
        .CLK_HZ(CLK_HZ), .BAUD(BAUD),
        .MEM_WORDS(MEM_WORDS), .MEM_INIT(MEM_INIT),
        .GPIO_W(8), .ENABLE_SRAM(1)
    ) u_soc (
        .clk(clk), .rst(rst),
        .uart_rx(uart_rx), .uart_tx(uart_tx),
        .uart_cts_n(1'b0), .uart_rts_n(),
        .gpio_out(gpio_out_w), .gpio_in(gpio_i),
        .sram_a(sram_addr), .sram_dout(sram_dout), .sram_din(sram_din),
        .sram_doe(sram_doe), .sram_ce_n(sram_ce_n),
        .sram_oe_n(sram_oe_n), .sram_we_n(sram_we_n),
        .halted(), .dbg_pc(), .dbg_instr(), .dbg_retire()
    );

    assign gpio_o   = gpio_out_w;
    assign user_led = gpio_out_w[0];
endmodule

`default_nettype wire
