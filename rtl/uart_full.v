// =====================================================================
// uart_full.v  -  Configurable UART peripheral (TX+RX) with interrupts
// ---------------------------------------------------------------------
// Register map (word offsets from the peripheral base):
//   0x00 TXDATA (W) : byte[7:0] to transmit (when tx_ready)
//   0x04 RXDATA (R) : received byte; reading clears rx_valid + errors
//   0x08 STATUS (R) : b0 tx_ready b1 rx_valid b2 frame_err b3 parity_err b4 overrun
//   0x0C CONFIG (RW): [15:0] clks_per_bit [19:16] data_bits
//                     [21:20] parity(0/1/2) [22] stop2
//   0x10 IEN    (RW): b0 rxne_ie  b1 idle_ie  b2 txe_ie   (interrupt enables)
//   0x14 IPEND  (R) : b0 rxne(=rx_valid) b1 idle b2 txe(=tx_ready)
//              (W1C) : write b1=1 to clear the latched IDLE event
//   0x18 IDLECFG(RW): [4:0] idle_bits  (idle bit-times -> IDLE event; 0 disables)
//
// `irq` (level) = (rx_valid & rxne_ie) | (idle_pend & idle_ie) | (tx_ready & txe_ie)
// IDLE = the RX line went quiet for idle_bits bit-times after a byte: the
// "receive to idle" event that delimits a whole variable-length message.
// =====================================================================
`default_nettype none

module uart_full #(
    parameter DEF_CLKS   = 1085,
    parameter DEF_DBITS  = 8,
    parameter DEF_PARITY = 0,
    parameter DEF_STOP2  = 0,
    parameter DEF_IDLE   = 12          // idle bit-times default
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        sel,
    input  wire        we,
    input  wire [7:0]  addr,
    input  wire [31:0] wdata,
    output reg  [31:0] rdata,
    input  wire        rx,
    output wire        tx,
    output wire        irq
);
    reg [15:0] cfg_clks;
    reg [3:0]  cfg_dbits;
    reg [1:0]  cfg_parity;
    reg        cfg_stop2;
    reg [4:0]  cfg_idle;
    reg [2:0]  ien;                    // interrupt enables
    reg [7:0]  rx_hold;
    reg        rx_valid, st_frame, st_parity, st_over, idle_pend;

    wire        tx_busy;
    wire        tx_ready = ~tx_busy;
    wire        rd_rx = sel & ~we & (addr[7:0]==8'h04);
    wire        tx_send = sel & we & (addr[7:0]==8'h00) & tx_ready;

    uart_tx_cfg u_tx (
        .clk(clk), .rst(rst), .send(tx_send), .data(wdata[7:0]),
        .clks_per_bit(cfg_clks), .data_bits(cfg_dbits),
        .parity_mode(cfg_parity), .stop2(cfg_stop2), .tx(tx), .busy(tx_busy)
    );

    wire [7:0] rx_byte; wire rx_v, rx_fe, rx_pe, rx_idle;
    uart_rx u_rx (
        .clk(clk), .rst(rst), .rx(rx),
        .clks_per_bit(cfg_clks), .data_bits(cfg_dbits),
        .parity_mode(cfg_parity), .stop2(cfg_stop2), .idle_bits(cfg_idle),
        .data(rx_byte), .valid(rx_v), .frame_err(rx_fe),
        .parity_err(rx_pe), .idle(rx_idle)
    );

    always @(posedge clk) begin
        if (rst) begin
            cfg_clks<=DEF_CLKS[15:0]; cfg_dbits<=DEF_DBITS[3:0];
            cfg_parity<=DEF_PARITY[1:0]; cfg_stop2<=DEF_STOP2[0];
            cfg_idle<=DEF_IDLE[4:0]; ien<=3'b0;
            rx_valid<=0; st_frame<=0; st_parity<=0; st_over<=0; rx_hold<=0; idle_pend<=0;
        end else begin
            if (sel & we) case (addr[7:0])
                8'h0C: begin cfg_clks<=wdata[15:0]; cfg_dbits<=wdata[19:16];
                             cfg_parity<=wdata[21:20]; cfg_stop2<=wdata[22]; end
                8'h10: ien <= wdata[2:0];
                8'h14: if (wdata[1]) idle_pend <= 1'b0;       // W1C clears IDLE
                8'h18: cfg_idle <= wdata[4:0];
                default: ;
            endcase
            // capture a received byte
            if (rx_v) begin
                if (rx_valid) st_over <= 1'b1;
                else begin rx_hold<=rx_byte; rx_valid<=1'b1;
                           st_frame<=rx_fe; st_parity<=rx_pe; end
            end
            if (rx_idle) idle_pend <= 1'b1;                   // latch IDLE event
            if (rd_rx) begin rx_valid<=0; st_frame<=0; st_parity<=0; st_over<=0; end
        end
    end

    assign irq = (rx_valid & ien[0]) | (idle_pend & ien[1]) | (tx_ready & ien[2]);

    always @(*) begin
        case (addr[7:0])
            8'h04:   rdata = {24'b0, rx_hold};
            8'h08:   rdata = {27'b0, st_over, st_parity, st_frame, rx_valid, tx_ready};
            8'h0C:   rdata = {9'b0, cfg_stop2, cfg_parity, cfg_dbits, cfg_clks};
            8'h10:   rdata = {29'b0, ien};
            8'h14:   rdata = {29'b0, tx_ready, idle_pend, rx_valid};
            8'h18:   rdata = {27'b0, cfg_idle};
            default: rdata = 32'b0;
        endcase
    end
endmodule

`default_nettype wire
