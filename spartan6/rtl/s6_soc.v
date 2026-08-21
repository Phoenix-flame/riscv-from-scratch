// =====================================================================
// s6_soc.v  -  The SoC: core + BRAM + UART + CLINT + GPIO + SRAM
// ---------------------------------------------------------------------
// Memory map (the top nibble picks the region, so the decoder is four
// bits wide and free):
//
//   0x0000_0000  RAM     unified code+data block RAM, MEM_WORDS x 32
//   0x1000_0000  UART    s6_uart
//   0x1001_0000  CLINT   msip / mtimecmp / mtime
//   0x1002_0000  GPIO
//   0x2000_0000  SYSCON  halt + a read-only description of the hardware
//   0x4000_0000  SRAM    512 KB IS61WV5128BLL (data only, not fetchable)
//
// SYSCON is worth a word: besides the halt register it reports the clock
// frequency, the RAM size and the SRAM size. Firmware reads those instead
// of hard-coding them, so re-synthesising at a different PLL setting does
// not silently break the UART baud rate.
//
// ---- bus protocol ------------------------------------------------------
// Writes complete in the cycle they are issued (`ready` high immediately).
// Reads take at least one wait state and return registered data, which is
// what a block RAM does anyway and what lets a read with a side effect
// (popping the UART RX FIFO) happen exactly once. Unmapped addresses
// answer ready=1 / rdata=0 rather than hanging the core.
// =====================================================================
`default_nettype none

module s6_soc #(
    parameter integer CLK_HZ      = 48_000_000,
    parameter integer BAUD        = 115200,
    parameter integer MEM_WORDS   = 4096,          // 16 KB of block RAM
    parameter         MEM_INIT    = "",
    parameter integer GPIO_W      = 8,
    parameter         ENABLE_SRAM = 1,
    parameter integer SRAM_BYTES  = 524288,        // 512 KB
    // ---- core options ----
    parameter         ENABLE_M    = 1,
    parameter         ENABLE_A    = 1,
    parameter         ENABLE_C    = 1,
    parameter         ENABLE_U    = 1,
    parameter         MUL_DSP     = 0,
    parameter         FAST_FETCH  = 1,
    parameter integer SRAM_RD_CYC = 2,
    parameter integer SRAM_WR_CYC = 2
) (
    input  wire              clk,
    input  wire              rst,

    // ---- UART ----
    input  wire              uart_rx,
    output wire              uart_tx,
    input  wire              uart_cts_n,
    output wire              uart_rts_n,

    // ---- GPIO ----
    output wire [GPIO_W-1:0] gpio_out,
    input  wire [GPIO_W-1:0] gpio_in,

    // ---- external SRAM ----
    output wire [18:0]       sram_a,
    output wire [7:0]        sram_dout,
    input  wire [7:0]        sram_din,
    output wire              sram_doe,
    output wire              sram_ce_n,
    output wire              sram_oe_n,
    output wire              sram_we_n,

    // ---- observation ----
    output wire              halted,
    output wire [31:0]       dbg_pc,
    output wire [31:0]       dbg_instr,
    output wire              dbg_retire
);
    // AW = log2(MEM_WORDS); a ladder, because XST rejects $clog2 here.
    localparam integer AW = (MEM_WORDS<=256)    ?  8 : (MEM_WORDS<=512)    ?  9 :
                            (MEM_WORDS<=1024)   ? 10 : (MEM_WORDS<=2048)   ? 11 :
                            (MEM_WORDS<=4096)   ? 12 : (MEM_WORDS<=8192)   ? 13 :
                            (MEM_WORDS<=16384)  ? 14 : (MEM_WORDS<=32768)  ? 15 :
                            (MEM_WORDS<=65536)  ? 16 : (MEM_WORDS<=131072) ? 17 : 18;
    localparam integer BAUDDIV  = CLK_HZ / BAUD;
    localparam integer TICK_DIV = (CLK_HZ / 1000000) < 1 ? 1 : (CLK_HZ / 1000000);

    // ---- core buses ----
    wire [31:0] iaddr, irdata;
    wire [31:0] daddr, dwdata, drdata;
    wire [3:0]  dwe;
    wire        dre, dready;
    wire [63:0] mtime;
    wire        timer_irq, soft_irq, ext_irq;
    wire        halt_r;

    s6_core #(
        .RESET_ADDR(32'h0000_0000),
        .ENABLE_M(ENABLE_M), .ENABLE_A(ENABLE_A), .ENABLE_C(ENABLE_C),
        .ENABLE_U(ENABLE_U), .MUL_DSP(MUL_DSP), .FAST_FETCH(FAST_FETCH)
    ) u_core (
        .clk(clk), .rst(rst),
        .ibus_addr(iaddr), .ibus_rdata(irdata),
        .dbus_addr(daddr), .dbus_we(dwe), .dbus_re(dre),
        .dbus_wdata(dwdata), .dbus_rdata(drdata), .dbus_ready(dready),
        .timer_irq(timer_irq), .soft_irq(soft_irq), .ext_irq(ext_irq),
        .mtime(mtime), .halt(halt_r),
        .pc_out(dbg_pc), .instr_out(dbg_instr), .retire_out(dbg_retire)
    );

    // =====================================================================
    // Address decode
    // =====================================================================
    wire sel_ram   = (daddr[31:28] == 4'h0);
    wire sel_uart  = (daddr[31:28] == 4'h1) && (daddr[19:16] == 4'h0);
    wire sel_clint = (daddr[31:28] == 4'h1) && (daddr[19:16] == 4'h1);
    wire sel_gpio  = (daddr[31:28] == 4'h1) && (daddr[19:16] == 4'h2);
    wire sel_sys   = (daddr[31:28] == 4'h2);
    wire sel_sram  = (ENABLE_SRAM != 0) && (daddr[31:28] == 4'h4);
    wire wr_any    = |dwe;

    // =====================================================================
    // Unified code + data block RAM
    // =====================================================================
    wire [31:0] ram_rdata;
    s6_ram #(.WORDS(MEM_WORDS), .INIT_FILE(MEM_INIT)) u_ram (
        .clk(clk),
        .a_addr(iaddr[AW+1:2]), .a_rdata(irdata),
        .b_addr(daddr[AW+1:2]),
        .b_we(sel_ram ? dwe : 4'b0000), .b_wdata(dwdata), .b_rdata(ram_rdata)
    );

    reg ram_rack;
    always @(posedge clk) ram_rack <= rst ? 1'b0 : (sel_ram & dre & ~ram_rack);
    wire ram_ready = (sel_ram & wr_any) | ram_rack;

    // =====================================================================
    // UART
    // =====================================================================
    wire [31:0] uart_rdata;
    wire        uart_ready, uart_irq;
    s6_uart #(.DEF_BAUDDIV(BAUDDIV[19:0])) u_uart (
        .clk(clk), .rst(rst),
        .sel(sel_uart), .re(dre), .be(sel_uart ? dwe : 4'b0000),
        .addr(daddr[7:0]), .wdata(dwdata),
        .rdata(uart_rdata), .ready(uart_ready),
        .rx(uart_rx), .tx(uart_tx),
        .cts_n(uart_cts_n), .rts_n(uart_rts_n), .irq(uart_irq)
    );

    // =====================================================================
    // CLINT
    // =====================================================================
    wire [31:0] clint_rdata;
    wire        clint_ready;
    s6_clint #(.TICK_DIV(TICK_DIV)) u_clint (
        .clk(clk), .rst(rst),
        .sel(sel_clint), .re(dre), .be(sel_clint ? dwe : 4'b0000),
        .addr(daddr[15:0]), .wdata(dwdata),
        .rdata(clint_rdata), .ready(clint_ready),
        .mtime(mtime), .timer_irq(timer_irq), .soft_irq(soft_irq)
    );

    // =====================================================================
    // GPIO
    // =====================================================================
    wire [31:0] gpio_rdata;
    wire        gpio_ready, gpio_irq;
    s6_gpio #(.WIDTH(GPIO_W)) u_gpio (
        .clk(clk), .rst(rst),
        .sel(sel_gpio), .re(dre), .be(sel_gpio ? dwe : 4'b0000),
        .addr(daddr[7:0]), .wdata(dwdata),
        .rdata(gpio_rdata), .ready(gpio_ready),
        .gpio_out(gpio_out), .gpio_in(gpio_in), .irq(gpio_irq)
    );

    assign ext_irq = uart_irq | gpio_irq;

    // =====================================================================
    // External SRAM
    // =====================================================================
    wire [31:0] sram_rdata;
    wire        sram_ready;
    generate
        if (ENABLE_SRAM) begin : g_sram
            s6_sram #(.RD_CYCLES(SRAM_RD_CYC), .WR_CYCLES(SRAM_WR_CYC)) u_sram (
                .clk(clk), .rst(rst),
                .sel(sel_sram), .re(dre), .be(sel_sram ? dwe : 4'b0000),
                .addr(daddr[18:0]), .wdata(dwdata),
                .rdata(sram_rdata), .ready(sram_ready),
                .sram_a(sram_a), .sram_dout(sram_dout), .sram_din(sram_din),
                .sram_doe(sram_doe), .sram_ce_n(sram_ce_n),
                .sram_oe_n(sram_oe_n), .sram_we_n(sram_we_n)
            );
        end else begin : g_no_sram
            assign sram_rdata = 32'd0;
            assign sram_ready = 1'b1;
            assign sram_a     = 19'd0;
            assign sram_dout  = 8'd0;
            assign sram_doe   = 1'b0;
            assign sram_ce_n  = 1'b1;
            assign sram_oe_n  = 1'b1;
            assign sram_we_n  = 1'b1;
        end
    endgenerate

    // =====================================================================
    // SYSCON: halt, plus a read-only description of this SoC
    // =====================================================================
    reg [31:0] sys_rdata;
    reg [31:0] tohost_r;
    reg        halt_q, sys_rack;

    always @(posedge clk) begin
        if (rst) begin
            halt_q <= 1'b0; tohost_r <= 32'd0; sys_rack <= 1'b0;
        end else begin
            sys_rack <= sel_sys & dre & ~sys_rack;
            if (sel_sys & wr_any & (daddr[7:0] == 8'h00)) begin
                tohost_r <= dwdata;
                halt_q   <= 1'b1;
            end
            if (sel_sys & dre & ~sys_rack) case (daddr[7:0])
                8'h00:   sys_rdata <= tohost_r;
                8'h04:   sys_rdata <= CLK_HZ;
                8'h08:   sys_rdata <= MEM_WORDS;
                8'h0C:   sys_rdata <= ENABLE_SRAM ? SRAM_BYTES : 32'd0;
                8'h10:   sys_rdata <= {30'b0, gpio_irq, uart_irq};
                default: sys_rdata <= 32'd0;
            endcase
        end
    end
    wire sys_ready = (sel_sys & wr_any) | sys_rack;

    assign halt_r = halt_q;
    assign halted = halt_q;

    // =====================================================================
    // Read-data and ready muxes
    // =====================================================================
    assign drdata = sel_uart  ? uart_rdata  :
                    sel_clint ? clint_rdata :
                    sel_gpio  ? gpio_rdata  :
                    sel_sram  ? sram_rdata  :
                    sel_sys   ? sys_rdata   :
                                ram_rdata;

    assign dready = sel_ram   ? ram_ready   :
                    sel_uart  ? uart_ready  :
                    sel_clint ? clint_ready :
                    sel_gpio  ? gpio_ready  :
                    sel_sram  ? sram_ready  :
                    sel_sys   ? sys_ready   :
                                1'b1;         // unmapped: never stall
endmodule

`default_nettype wire
