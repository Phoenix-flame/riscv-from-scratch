// =====================================================================
// soc_axi.v  -  PL-side SoC that masters AXI4-Lite to the PS
// ---------------------------------------------------------------------
// The stall-capable core with local block RAM for code/data, plus an
// AXI4-Lite master that bridges a high address window out to the PS. On a
// real Zynq the AXI master pins connect to a PS slave port (AXI-GP to PS
// peripherals, or an AXI port into the DDR controller); here they leave the
// module so a testbench (or Vivado's PS block) can drive the other end.
//
//   0x0000_0000  local RAM   (block RAM: code mirror + data + stack)
//   0x2000_0000  SYSCON       (write -> halt)
//   0x4000_0000  PS window    (-> AXI4-Lite master -> DDR / PS peripherals)
//
// The local RAM and SYSCON answer in one cycle (dmem_ready tied high for
// their region); the PS window's ready comes from the AXI master only when
// the PS responds, which is exactly what stalls the core.
// =====================================================================
`default_nettype none

module soc_axi #(
    parameter ROM_WORDS = 4096,
    parameter RAM_WORDS = 2048,
    parameter IMEM_INIT = "",
    parameter DMEM_INIT = ""
) (
    input  wire        clk,
    input  wire        rst,
    output wire        halted,
    // ---- AXI4-Lite master to the PS ----
    output wire [31:0] m_awaddr,  output wire [2:0] m_awprot, output wire m_awvalid, input wire m_awready,
    output wire [31:0] m_wdata,   output wire [3:0] m_wstrb,  output wire m_wvalid,  input wire m_wready,
    input  wire [1:0]  m_bresp,   input  wire       m_bvalid, output wire m_bready,
    output wire [31:0] m_araddr,  output wire [2:0] m_arprot, output wire m_arvalid, input wire m_arready,
    input  wire [31:0] m_rdata,   input  wire [1:0] m_rresp,  input  wire m_rvalid,  output wire m_rready
);
    wire [31:0] iaddr, irdata, daddr, dwdata, drdata;
    wire [3:0]  dwe;
    wire        dre, dready;
    wire        halt_q;

    cpu_mc_stall u_core (
        .clk(clk), .rst(rst), .timer_irq(1'b0), .ext_irq(1'b0), .halt(halt_q),
        .imem_addr(iaddr), .imem_rdata(irdata),
        .dmem_addr(daddr), .dmem_we(dwe), .dmem_re(dre),
        .dmem_wdata(dwdata), .dmem_rdata(drdata), .dmem_ready(dready),
        .pc_out()
    );

    bram_rom #(.WORDS(ROM_WORDS), .INIT_FILE(IMEM_INIT)) u_rom (
        .clk(clk), .addr_word(iaddr[$clog2(ROM_WORDS)+1:2]), .rdata(irdata)
    );

    wire sel_ram = (daddr[31:28] == 4'h0);
    wire sel_sys = (daddr[31:28] == 4'h2);
    wire sel_axi = (daddr[31:28] == 4'h4);
    wire wr_any  = |dwe;

    // ---- local RAM (always ready) ----
    wire [31:0] ram_rdata;
    bram_ram #(.WORDS(RAM_WORDS), .INIT_FILE(DMEM_INIT)) u_ram (
        .clk(clk), .addr_word(daddr[$clog2(RAM_WORDS)+1:2]),
        .we(sel_ram ? dwe : 4'b0000), .wdata(dwdata), .rdata(ram_rdata)
    );

    // ---- AXI4-Lite master for the PS window ----
    wire [31:0] axi_rdata;
    wire        axi_ready;
    wire        axi_req = sel_axi & (dre | wr_any);     // active only in the MEM phase
    axi_lite_master u_axi (
        .clk(clk), .rst(rst),
        .req(axi_req), .we(wr_any), .addr(daddr), .wdata(dwdata), .wstrb(dwe),
        .rdata(axi_rdata), .ready(axi_ready),
        .m_awaddr(m_awaddr), .m_awprot(m_awprot), .m_awvalid(m_awvalid), .m_awready(m_awready),
        .m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_wvalid(m_wvalid), .m_wready(m_wready),
        .m_bresp(m_bresp), .m_bvalid(m_bvalid), .m_bready(m_bready),
        .m_araddr(m_araddr), .m_arprot(m_arprot), .m_arvalid(m_arvalid), .m_arready(m_arready),
        .m_rdata(m_rdata), .m_rresp(m_rresp), .m_rvalid(m_rvalid), .m_rready(m_rready)
    );

    // ---- read data + ready mux: PS window is variable-latency, the rest 1-cycle
    assign drdata = sel_axi ? axi_rdata : ram_rdata;
    assign dready = sel_axi ? axi_ready : 1'b1;

    // ---- SYSCON ----
    reg halt_r;
    always @(posedge clk) begin
        if (rst)                   halt_r <= 1'b0;
        else if (sel_sys & wr_any) halt_r <= 1'b1;
    end
    assign halt_q = halt_r;
    assign halted = halt_r;
endmodule

`default_nettype wire
