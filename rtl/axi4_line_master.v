// =====================================================================
// axi4_line_master.v  -  cache lines over an AXI4 burst master port
// ---------------------------------------------------------------------
// Step 36's AXI4-Lite master moved one word per handshake, which is all
// a PS register needs. DDR wants bursts, and a cache already thinks in
// lines, so this turns each mem_slow-style line request into one AXI4
// INCR burst of LINE_WORDS 32-bit beats:
//
//   read   AR (len = LINE_WORDS-1, size = 4 bytes, INCR) -> LINE_WORDS R beats
//   write  AW + LINE_WORDS W beats (WLAST on the last) -> one B
//
// One transaction is in flight at a time and AXI IDs are 0, so nothing
// can come back out of order. AW and W are offered together (AXI lets a
// slave take them in either order). A response other than OKAY is
// latched in `err` -- the data of such a read is not trustworthy.
//
// ADDR_OFFSET relocates the window: the core's RAM at 0x8000_0000 can sit
// anywhere in the slave's map (on a Zynq, somewhere in PS DDR behind an
// S_AXI_HP port; those ports speak AXI3, which differs from this only in
// the WID signal (0 here) and allows the same 8-beat bursts).
// =====================================================================
`default_nettype none

module axi4_line_master #(
    parameter        LINE_WORDS  = 8,
    parameter [31:0] ADDR_OFFSET = 32'd0      // added to every address
) (
    input  wire                     clk,
    input  wire                     rst,
    // ---- line side (mem_slow protocol, bursts only) ----
    input  wire                     req,
    input  wire                     we,
    input  wire [31:0]              addr,
    input  wire [32*LINE_WORDS-1:0] wdata,
    output reg                      done,
    output reg  [32*LINE_WORDS-1:0] rdata,
    output reg                      err,
    // ---- AXI4 master ----
    output reg  [31:0]              m_axi_awaddr,
    output wire [7:0]               m_axi_awlen,
    output wire [2:0]               m_axi_awsize,
    output wire [1:0]               m_axi_awburst,
    output wire [3:0]               m_axi_awcache,
    output wire [2:0]               m_axi_awprot,
    output reg                      m_axi_awvalid,
    input  wire                     m_axi_awready,
    output wire [31:0]              m_axi_wdata,
    output wire [3:0]               m_axi_wstrb,
    output wire                     m_axi_wlast,
    output reg                      m_axi_wvalid,
    input  wire                     m_axi_wready,
    input  wire [1:0]               m_axi_bresp,
    input  wire                     m_axi_bvalid,
    output wire                     m_axi_bready,
    output reg  [31:0]              m_axi_araddr,
    output wire [7:0]               m_axi_arlen,
    output wire [2:0]               m_axi_arsize,
    output wire [1:0]               m_axi_arburst,
    output wire [3:0]               m_axi_arcache,
    output wire [2:0]               m_axi_arprot,
    output reg                      m_axi_arvalid,
    input  wire                     m_axi_arready,
    input  wire [31:0]              m_axi_rdata,
    input  wire [1:0]               m_axi_rresp,
    input  wire                     m_axi_rlast,
    input  wire                     m_axi_rvalid,
    output wire                     m_axi_rready
);
    localparam LB = $clog2(LINE_WORDS);
    localparam S_IDLE = 2'd0, S_READ = 2'd1, S_WRITE = 2'd2, S_RESP = 2'd3;

    reg [1:0]  state;
    reg [LB:0] beat;
    reg [32*LINE_WORDS-1:0] l_wdata;

    assign m_axi_awlen   = LINE_WORDS - 1;
    assign m_axi_arlen   = LINE_WORDS - 1;
    assign m_axi_awsize  = 3'd2;              // 4 bytes a beat
    assign m_axi_arsize  = 3'd2;
    assign m_axi_awburst = 2'b01;             // INCR
    assign m_axi_arburst = 2'b01;
    assign m_axi_awcache = 4'b0011;           // normal, non-cacheable, bufferable
    assign m_axi_arcache = 4'b0011;
    assign m_axi_awprot  = 3'b000;
    assign m_axi_arprot  = 3'b000;
    assign m_axi_wdata   = l_wdata[32*beat[LB-1:0] +: 32];
    assign m_axi_wstrb   = 4'b1111;
    assign m_axi_wlast   = (beat == LINE_WORDS - 1);
    assign m_axi_bready  = (state == S_RESP);
    assign m_axi_rready  = (state == S_READ);

    wire [31:0] line_addr = {addr[31:LB+2], {(LB+2){1'b0}}} + ADDR_OFFSET;

    always @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            state <= S_IDLE; beat <= 0; err <= 1'b0;
            m_axi_awvalid <= 1'b0; m_axi_wvalid <= 1'b0; m_axi_arvalid <= 1'b0;
            m_axi_awaddr <= 32'd0; m_axi_araddr <= 32'd0;
        end else case (state)
            S_IDLE: if (req && !done) begin
                beat <= 0;
                if (we) begin
                    l_wdata <= wdata;
                    m_axi_awaddr <= line_addr; m_axi_awvalid <= 1'b1; m_axi_wvalid <= 1'b1;
                    state <= S_WRITE;
                end else begin
                    m_axi_araddr <= line_addr; m_axi_arvalid <= 1'b1;
                    state <= S_READ;
                end
            end
            S_READ: begin
                if (m_axi_arready) m_axi_arvalid <= 1'b0;
                if (m_axi_rvalid) begin
                    rdata[32*beat[LB-1:0] +: 32] <= m_axi_rdata;
                    if (m_axi_rresp != 2'b00) err <= 1'b1;
                    beat <= beat + 1'b1;
                    if (m_axi_rlast) begin done <= 1'b1; state <= S_IDLE; end
                end
            end
            S_WRITE: begin
                if (m_axi_awready) m_axi_awvalid <= 1'b0;
                if (m_axi_wvalid && m_axi_wready) begin
                    beat <= beat + 1'b1;
                    if (m_axi_wlast) m_axi_wvalid <= 1'b0;
                end
                // all beats taken and the address too: wait for the response
                if ((~m_axi_awvalid | m_axi_awready) &&
                    (~m_axi_wvalid  | (m_axi_wready & m_axi_wlast)))
                    state <= S_RESP;
            end
            S_RESP: if (m_axi_bvalid) begin
                if (m_axi_bresp != 2'b00) err <= 1'b1;
                done <= 1'b1; state <= S_IDLE;
            end
        endcase
    end
endmodule

`default_nettype wire
