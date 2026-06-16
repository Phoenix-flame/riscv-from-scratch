// =====================================================================
// soc_c.v  -  Minimal SoC for the RV32IMC core: CPU + BRAM + SYSCON
// ---------------------------------------------------------------------
// Just enough system to run compiled rv32imc programs: the compressed-
// instruction core, a word-wide instruction ROM (which is exactly what makes
// unaligned fetch interesting), data RAM, and the SYSCON halt register.
//
//   0x0000_0000  RAM
//   0x2000_0000  SYSCON (write -> halt)
// =====================================================================
`default_nettype none

module soc_c #(
    parameter ROM_WORDS = 4096,
    parameter RAM_WORDS = 4096,
    parameter IMEM_INIT = "",
    parameter DMEM_INIT = ""
) (
    input  wire clk,
    input  wire rst,
    output wire halted
);
    wire [31:0] iaddr, irdata, daddr, dwdata, drdata;
    wire [3:0]  dwe;
    wire        halt_q;

    cpu_mc_c u_core (
        .clk(clk), .rst(rst), .timer_irq(1'b0), .ext_irq(1'b0), .halt(halt_q),
        .imem_addr(iaddr), .imem_rdata(irdata),
        .dmem_addr(daddr), .dmem_we(dwe), .dmem_re(),
        .dmem_wdata(dwdata), .dmem_rdata(drdata),
        .pc_out()
    );

    bram_rom #(.WORDS(ROM_WORDS), .INIT_FILE(IMEM_INIT)) u_rom (
        .clk(clk), .addr_word(iaddr[$clog2(ROM_WORDS)+1:2]), .rdata(irdata)
    );

    wire sel_ram = (daddr[31:28] == 4'h0);
    wire sel_sys = (daddr[31:28] == 4'h2);
    wire wr_any  = |dwe;

    bram_ram #(.WORDS(RAM_WORDS), .INIT_FILE(DMEM_INIT)) u_ram (
        .clk(clk), .addr_word(daddr[$clog2(RAM_WORDS)+1:2]),
        .we(sel_ram ? dwe : 4'b0000), .wdata(dwdata), .rdata(drdata)
    );

    reg halt_r;
    always @(posedge clk) begin
        if (rst)                   halt_r <= 1'b0;
        else if (sel_sys & wr_any) halt_r <= 1'b1;
    end
    assign halt_q = halt_r;
    assign halted = halt_r;
endmodule

`default_nettype wire
