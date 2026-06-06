// =====================================================================
// debug_module.v  -  a minimal Debug Module (DM) for cpu_core_dbg
// ---------------------------------------------------------------------
// Exposes a tiny register interface (a DMI) that a host debugger drives
// (over JTAG/UART on hardware; directly from a testbench in sim). It
// translates register accesses into the core's debug primitives and into
// memory accesses on the system bus (used while the core is halted).
//
//   DMI register map (byte address on dmi_addr):
//     0x00 CONTROL  (W): bit0 halt, bit1 resume, bit2 step
//     0x04 STATUS   (R): bit0 halted
//     0x08 REGSEL   (W): GPR index 0..31
//     0x0C REGDATA  (R/W): read/write the selected GPR (while halted)
//     0x10 DPC      (R/W): read/write the PC
//     0x14 MEMADDR  (W): address for memory access
//     0x18 MEMDATA  (R/W): read/write memory at MEMADDR (while halted)
//     0x1C BPSEL    (W): breakpoint index 0..NBP-1
//     0x20 BPSET    (W): set breakpoint[BPSEL] = wdata, enable it
//     0x24 BPCLR    (W): disable breakpoint[BPSEL]
// =====================================================================
`default_nettype none

module debug_module #(parameter NBP = 4) (
    input  wire        clk,
    input  wire        rst,
    // DMI slave (host transport)
    input  wire        dmi_sel,
    input  wire        dmi_we,
    input  wire [7:0]  dmi_addr,
    input  wire [31:0] dmi_wdata,
    output reg  [31:0] dmi_rdata,
    // core debug master
    output reg         dbg_halt_req,
    output reg         dbg_resume,
    output reg         dbg_step,
    input  wire        dbg_halted,
    input  wire [31:0] dbg_pc,
    output reg         dbg_pc_we,
    output reg  [31:0] dbg_pc_wdata,
    output wire [4:0]  dbg_reg_addr,
    input  wire [31:0] dbg_reg_rdata,
    output reg         dbg_reg_we,
    output reg  [31:0] dbg_reg_wdata,
    output reg  [NBP-1:0]    bp_en,
    output reg  [NBP*32-1:0] bp_addr_flat,
    // memory master (system bus, used while halted)
    output reg         dm_mem_req,
    output reg         dm_mem_we,
    output reg  [31:0] dm_mem_addr,
    output reg  [31:0] dm_mem_wdata,
    input  wire [31:0] dm_mem_rdata
);
    reg [4:0]  regsel;
    reg [31:0] memaddr;
    reg [$clog2(NBP)-1:0] bpsel;
    assign dbg_reg_addr = regsel;

    wire wr = dmi_sel & dmi_we;
    wire rd = dmi_sel & ~dmi_we;

    integer k;
    always @(posedge clk) begin
        if (rst) begin
            dbg_halt_req <= 1'b0; regsel <= 5'd0; memaddr <= 32'd0; bpsel <= 0;
            bp_en <= {NBP{1'b0}}; bp_addr_flat <= {(NBP*32){1'b0}};
        end else begin
            // persistent state writes
            if (wr) case (dmi_addr)
                8'h00: begin
                    if (dmi_wdata[0]) dbg_halt_req <= 1'b1;          // halt
                    if (dmi_wdata[1]) dbg_halt_req <= 1'b0;          // resume clears haltreq
                    if (dmi_wdata[2]) dbg_halt_req <= 1'b0;          // step clears haltreq
                end
                8'h08: regsel  <= dmi_wdata[4:0];
                8'h14: memaddr <= dmi_wdata;
                8'h1C: bpsel   <= dmi_wdata[$clog2(NBP)-1:0];
                8'h20: begin bp_addr_flat[bpsel*32 +: 32] <= dmi_wdata; bp_en[bpsel] <= 1'b1; end
                8'h24: bp_en[bpsel] <= 1'b0;
                default: ;
            endcase
        end
    end

    // one-cycle command pulses + combinational read data / memory drive
    always @(*) begin
        dbg_resume    = wr && (dmi_addr==8'h00) && dmi_wdata[1];
        dbg_step      = wr && (dmi_addr==8'h00) && dmi_wdata[2];
        dbg_reg_we    = wr && (dmi_addr==8'h0C);
        dbg_reg_wdata = dmi_wdata;
        dbg_pc_we     = wr && (dmi_addr==8'h10);
        dbg_pc_wdata  = dmi_wdata;

        // memory access on MEMDATA (0x18)
        dm_mem_req    = dmi_sel && (dmi_addr==8'h18);
        dm_mem_we     = wr && (dmi_addr==8'h18);
        dm_mem_addr   = memaddr;
        dm_mem_wdata  = dmi_wdata;

        case (dmi_addr)
            8'h04:   dmi_rdata = {31'b0, dbg_halted};
            8'h0C:   dmi_rdata = dbg_reg_rdata;
            8'h10:   dmi_rdata = dbg_pc;
            8'h18:   dmi_rdata = dm_mem_rdata;
            default: dmi_rdata = 32'd0;
        endcase
    end
endmodule

`default_nettype wire
