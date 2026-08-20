// =====================================================================
// s6_uart.v  -  UART peripheral: FIFOs, fractional baud, interrupts
// ---------------------------------------------------------------------
// Register map (byte offsets from the peripheral base):
//
//   0x00 RXTX    W  [7:0]  push a byte into the TX FIFO
//                R  [7:0]  pop a byte from the RX FIFO
//                          [8] the byte is valid (the FIFO was not empty)
//   0x04 STATUS  R  b0 tx_empty   b1 tx_full   b2 tx_busy
//                   b3 rx_empty   b4 rx_full
//                   b5 overrun    b6 frame_err b7 parity_err
//                   b8 idle_pending           b9 cts_n (raw pin)
//   0x08 CTRL    RW b0 tx_en      b1 rx_en     b2 loopback
//                   b3 rts_en     b4 tx_clr(W) b5 rx_clr(W)  b6 cts_en
//                   b9:8 parity ([9] enable, [8] odd)
//                   b10  stop2    b14:11 data_bits (5..8)
//   0x0C BAUD    RW [19:0] clocks per bit = f_clk / baud
//   0x10 IE      RW interrupt enables, same bit numbering as IP
//   0x14 IP      R  b0 rx_notempty  b1 rx_watermark  b2 tx_empty
//                   b3 tx_watermark b4 idle          b5 error
//                W1C write 1 to b4/b5 to clear the latched idle / errors
//   0x18 LEVEL   R  [7:0] TX fill level, [15:8] RX fill level
//   0x1C WMARK   RW [3:0] tx watermark (IRQ when tx level <= wm)
//                   [11:8] rx watermark (IRQ when rx level >= wm)
//   0x20 IDLECFG RW [4:0] idle bit-times before the IDLE event (0 = off)
//
// ---- the baud generator ------------------------------------------------
// BAUD holds clocks-per-bit, not a prescaler, and the oversample tick is
// produced by a phase accumulator: add 16 every clock, emit a tick and
// subtract when the accumulator reaches clocks-per-bit. The tick rate is
// then exactly 16 x f_clk / clocks_per_bit with no rounding drift, so odd
// board clocks (the Posedge One runs off 24 MHz) still hit standard baud
// rates within a fraction of a percent. Programming it is one divide:
//
//     BAUD = f_clk / baud       e.g. 48 MHz / 115200 = 417
//
// ---- bus protocol ------------------------------------------------------
// Reads take one wait state and the read data is registered, so a read
// with a side effect (popping the RX FIFO) happens exactly once even
// though the core holds `re` high until it sees `ready`. Writes complete
// in the cycle they are issued.
// =====================================================================
`default_nettype none

module s6_uart #(
    parameter DEF_BAUDDIV = 20'd417,      // 48 MHz / 115200
    parameter FIFO_DEPTH  = 16
) (
    input  wire        clk,
    input  wire        rst,

    // ---- bus ----
    input  wire        sel,
    input  wire        re,
    input  wire [3:0]  be,               // byte enables; any bit set = write
    input  wire [7:0]  addr,
    input  wire [31:0] wdata,
    output reg  [31:0] rdata,
    output wire        ready,

    // ---- pins ----
    input  wire        rx,
    output wire        tx,
    input  wire        cts_n,            // tie low if unused
    output wire        rts_n,
    output wire        irq
);
    localparam LW = $clog2(FIFO_DEPTH);

    // ---- configuration registers ----
    reg [19:0] bauddiv;
    reg        c_tx_en, c_rx_en, c_loop, c_rts_en, c_cts_en, c_stop2;
    reg [1:0]  c_parity;
    reg [3:0]  c_dbits;
    reg [5:0]  ien;
    reg [3:0]  wm_tx, wm_rx;
    reg [4:0]  idle_cfg;

    // ---- sticky status ----
    reg st_over, st_frame, st_parity, st_idle;

    // ---- bus handshake -------------------------------------------------
    wire wr = sel & (|be);
    wire rd = sel & re;
    reg  rd_ack;
    always @(posedge clk) rd_ack <= rst ? 1'b0 : (rd & ~rd_ack);
    wire rd_first = rd & ~rd_ack;        // the one cycle the read "happens"
    assign ready = wr | rd_ack;

    // =====================================================================
    // 16x oversample tick: a phase accumulator, so any clock/baud pair works
    // =====================================================================
    reg  [19:0] acc;
    reg         os_tick;
    wire [20:0] acc_next = {1'b0, acc} + 21'd16;
    wire        tick_now = (acc_next >= {1'b0, bauddiv}) & (bauddiv >= 20'd16);

    always @(posedge clk) begin
        if (rst) begin
            acc <= 20'd0; os_tick <= 1'b0;
        end else begin
            os_tick <= tick_now;
            acc     <= tick_now ? (acc_next - {1'b0, bauddiv}) : acc_next[19:0];
        end
    end

    // =====================================================================
    // FIFOs
    // =====================================================================
    wire [7:0]    txf_rdata, rxf_rdata;
    wire          txf_full, txf_empty, rxf_full, rxf_empty;
    wire [LW:0]   txf_level, rxf_level;
    // widened once, so the watermark compares do not depend on FIFO_DEPTH
    wire [7:0]    tx_lvl = {{(7-LW){1'b0}}, txf_level};
    wire [7:0]    rx_lvl = {{(7-LW){1'b0}}, rxf_level};

    wire       tx_busy;
    wire       cts_ok    = ~c_cts_en | ~cts_n;
    wire       tx_start  = c_tx_en & ~tx_busy & ~txf_empty & cts_ok;
    reg        tx_start_q;
    always @(posedge clk) tx_start_q <= rst ? 1'b0 : (tx_start & ~tx_start_q);

    wire       txf_push  = wr & (addr[7:0] == 8'h00);
    wire       txf_pop   = tx_start_q;

    s6_fifo #(.WIDTH(8), .DEPTH(FIFO_DEPTH)) u_txf (
        .clk(clk), .rst(rst), .clr(wr & (addr[7:0] == 8'h08) & wdata[4]),
        .wr(txf_push), .wdata(wdata[7:0]),
        .rd(txf_pop),  .rdata(txf_rdata),
        .full(txf_full), .empty(txf_empty), .level(txf_level)
    );

    wire [7:0] rx_byte;
    wire       rx_valid, rx_fe, rx_pe, rx_idle;
    wire       rxf_push = rx_valid & c_rx_en & ~rxf_full;
    wire       rxf_pop  = rd_first & (addr[7:0] == 8'h00) & ~rxf_empty;

    s6_fifo #(.WIDTH(8), .DEPTH(FIFO_DEPTH)) u_rxf (
        .clk(clk), .rst(rst), .clr(wr & (addr[7:0] == 8'h08) & wdata[5]),
        .wr(rxf_push), .wdata(rx_byte),
        .rd(rxf_pop),  .rdata(rxf_rdata),
        .full(rxf_full), .empty(rxf_empty), .level(rxf_level)
    );

    // =====================================================================
    // Serialiser / deserialiser
    // =====================================================================
    wire tx_line;
    s6_uart_tx u_tx (
        .clk(clk), .rst(rst), .os_tick(os_tick),
        .send(tx_start_q), .data(txf_rdata),
        .data_bits(c_dbits), .parity(c_parity), .stop2(c_stop2),
        .tx(tx_line), .busy(tx_busy)
    );

    // Loopback feeds the transmitter straight back into the receiver, so
    // firmware can self-test the whole path with no cable attached.
    wire rx_line = c_loop ? tx_line : rx;

    s6_uart_rx u_rx (
        .clk(clk), .rst(rst), .os_tick(os_tick), .rx(rx_line),
        .data_bits(c_dbits), .parity(c_parity), .idle_bits(idle_cfg),
        .data(rx_byte), .valid(rx_valid),
        .frame_err(rx_fe), .parity_err(rx_pe), .idle(rx_idle)
    );

    assign tx    = c_loop ? 1'b1 : tx_line;
    // RTS is asserted (low) while we still have room for another watermark
    // worth of bytes; deasserted when the RX FIFO fills past it.
    assign rts_n = ~(c_rts_en ? (rx_lvl < {4'b0, wm_rx}) : 1'b1);

    // =====================================================================
    // Control / status registers
    // =====================================================================
    always @(posedge clk) begin
        if (rst) begin
            bauddiv  <= DEF_BAUDDIV;
            c_tx_en  <= 1'b1; c_rx_en <= 1'b1; c_loop <= 1'b0;
            c_rts_en <= 1'b0; c_cts_en <= 1'b0; c_stop2 <= 1'b0;
            c_parity <= 2'b00; c_dbits <= 4'd8;
            ien      <= 6'd0;
            wm_tx    <= 4'd0; wm_rx <= 4'd1;
            idle_cfg <= 5'd12;
            st_over  <= 1'b0; st_frame <= 1'b0; st_parity <= 1'b0; st_idle <= 1'b0;
        end else begin
            if (wr) case (addr[7:0])
                8'h08: begin
                    c_tx_en  <= wdata[0];  c_rx_en  <= wdata[1];
                    c_loop   <= wdata[2];  c_rts_en <= wdata[3];
                    c_cts_en <= wdata[6];
                    c_parity <= wdata[9:8]; c_stop2 <= wdata[10];
                    c_dbits  <= (wdata[14:11] >= 4'd5 && wdata[14:11] <= 4'd8)
                                ? wdata[14:11] : 4'd8;
                end
                8'h0C: bauddiv  <= wdata[19:0];
                8'h10: ien      <= wdata[5:0];
                8'h14: begin                                   // W1C
                    if (wdata[4]) st_idle <= 1'b0;
                    if (wdata[5]) begin
                        st_over <= 1'b0; st_frame <= 1'b0; st_parity <= 1'b0;
                    end
                end
                8'h1C: begin wm_tx <= wdata[3:0]; wm_rx <= wdata[11:8]; end
                8'h20: idle_cfg <= wdata[4:0];
                default: ;
            endcase

            // error latches
            if (rx_valid & c_rx_en) begin
                if (rxf_full) st_over <= 1'b1;
                if (rx_fe)    st_frame <= 1'b1;
                if (rx_pe)    st_parity <= 1'b1;
            end
            if (rx_idle) st_idle <= 1'b1;
        end
    end

    // =====================================================================
    // Interrupts
    // =====================================================================
    wire [5:0] ipend = {
        st_over | st_frame | st_parity,                     // b5 error
        st_idle,                                            // b4 idle
        tx_lvl <= {4'b0, wm_tx},                            // b3 tx watermark
        txf_empty & ~tx_busy,                               // b2 tx empty
        rx_lvl >= {4'b0, wm_rx},                            // b1 rx watermark
        ~rxf_empty                                          // b0 rx not empty
    };
    assign irq = |(ipend & ien);

    // =====================================================================
    // Read mux (registered: `rdata` is captured on the first read cycle)
    // =====================================================================
    reg [31:0] rd_mux;
    always @(*) begin
        case (addr[7:0])
            8'h00: rd_mux = {23'b0, ~rxf_empty, rxf_rdata};
            8'h04: rd_mux = {22'b0, cts_n, st_idle, st_parity, st_frame, st_over,
                             rxf_full, rxf_empty, tx_busy, txf_full, txf_empty};
            8'h08: rd_mux = {17'b0, c_dbits, c_stop2, c_parity, 1'b0, c_cts_en,
                             2'b00, c_rts_en, c_loop, c_rx_en, c_tx_en};
            8'h0C: rd_mux = {12'b0, bauddiv};
            8'h10: rd_mux = {26'b0, ien};
            8'h14: rd_mux = {26'b0, ipend};
            8'h18: rd_mux = {16'b0, rx_lvl, tx_lvl};
            8'h1C: rd_mux = {20'b0, wm_rx, 4'b0, wm_tx};
            8'h20: rd_mux = {27'b0, idle_cfg};
            default: rd_mux = 32'd0;
        endcase
    end

    always @(posedge clk)
        if (rd_first) rdata <= rd_mux;
endmodule

`default_nettype wire
