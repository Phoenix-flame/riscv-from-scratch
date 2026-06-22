// =====================================================================
// axi_lite_master.v  -  Adapter: this core's simple bus -> AXI4-Lite master
// ---------------------------------------------------------------------
// Turns one request on the core's data bus into a single AXI4-Lite
// transaction on the five AXI channels, then pulses `ready` back so the
// stall-capable core can leave its MEM state. This is the thing a Zynq PL
// design instantiates to reach the PS: an AXI-GP master into PS peripherals,
// or (functionally) an AXI port into PS DDR.
//
//   write : drive AW + W, wait both accepted, wait the B response, ack.
//   read  : drive AR, wait accepted, wait R data, latch it, ack.
//
// AXI4-Lite carries exactly one 32-bit beat per transaction -- no bursts --
// which matches a core that issues one word at a time. Burst-capable AXI4
// (AXI-HP for DDR bandwidth) only pays off once a cache or DMA engine
// generates multi-beat requests; see the step doc.
// =====================================================================
`default_nettype none

module axi_lite_master (
    input  wire        clk,
    input  wire        rst,

    // ---- core side (simple request/ack) ----
    input  wire        req,          // a transaction is requested (held until ack)
    input  wire        we,           // 1 = write, 0 = read
    input  wire [31:0] addr,
    input  wire [31:0] wdata,
    input  wire [3:0]  wstrb,
    output reg  [31:0] rdata,
    output reg         ready,        // 1-cycle pulse: transaction complete

    // ---- AXI4-Lite master: write address ----
    output reg  [31:0] m_awaddr,
    output wire [2:0]  m_awprot,
    output reg         m_awvalid,
    input  wire        m_awready,
    // ---- write data ----
    output reg  [31:0] m_wdata,
    output reg  [3:0]  m_wstrb,
    output reg         m_wvalid,
    input  wire        m_wready,
    // ---- write response ----
    input  wire [1:0]  m_bresp,
    input  wire        m_bvalid,
    output reg         m_bready,
    // ---- read address ----
    output reg  [31:0] m_araddr,
    output wire [2:0]  m_arprot,
    output reg         m_arvalid,
    input  wire        m_arready,
    // ---- read data ----
    input  wire [31:0] m_rdata,
    input  wire [1:0]  m_rresp,
    input  wire        m_rvalid,
    output reg         m_rready
);
    assign m_awprot = 3'b000;
    assign m_arprot = 3'b000;

    localparam IDLE=3'd0, WR=3'd1, WRESP=3'd2, RD=3'd3, RDATA=3'd4, ACK=3'd5;
    reg [2:0] state;
    reg       aw_done, w_done;

    always @(posedge clk) begin
        if (rst) begin
            state    <= IDLE;
            ready    <= 1'b0;
            m_awvalid<= 1'b0; m_wvalid <= 1'b0; m_bready <= 1'b0;
            m_arvalid<= 1'b0; m_rready <= 1'b0;
            aw_done  <= 1'b0; w_done   <= 1'b0;
            rdata    <= 32'd0;
        end else begin
            ready <= 1'b0;                              // default: single-cycle pulse
            case (state)
                IDLE: if (req) begin
                    if (we) begin
                        m_awaddr <= addr; m_awvalid <= 1'b1;
                        m_wdata  <= wdata; m_wstrb <= wstrb; m_wvalid <= 1'b1;
                        aw_done  <= 1'b0; w_done <= 1'b0;
                        state    <= WR;
                    end else begin
                        m_araddr <= addr; m_arvalid <= 1'b1;
                        state    <= RD;
                    end
                end

                // ---- write: AW and W handshakes (independent) ----
                WR: begin
                    if (m_awvalid && m_awready) begin m_awvalid <= 1'b0; aw_done <= 1'b1; end
                    if (m_wvalid  && m_wready ) begin m_wvalid  <= 1'b0; w_done  <= 1'b1; end
                    if ((aw_done || (m_awvalid && m_awready)) &&
                        (w_done  || (m_wvalid  && m_wready ))) begin
                        m_bready <= 1'b1;
                        state    <= WRESP;
                    end
                end
                WRESP: if (m_bvalid) begin
                    m_bready <= 1'b0;
                    ready    <= 1'b1;                   // accept regardless of bresp
                    state    <= ACK;
                end

                // ---- read: AR handshake, then R ----
                RD: if (m_arvalid && m_arready) begin
                    m_arvalid <= 1'b0;
                    m_rready  <= 1'b1;
                    state     <= RDATA;
                end
                RDATA: if (m_rvalid) begin
                    rdata    <= m_rdata;
                    m_rready <= 1'b0;
                    ready    <= 1'b1;
                    state    <= ACK;
                end

                // one settling cycle so the core drops `req` before we re-arm
                ACK: state <= IDLE;

                default: state <= IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
