// =====================================================================
// soc_libc.v  -  SoC for running picolibc programs (printf + malloc)
// ---------------------------------------------------------------------
// The multi-cycle BRAM core with a generous 64 KB data RAM (so malloc has a
// real heap), the simulation UART (a TX write prints the byte), and SYSCON.
// The program image is mirrored into both the instruction ROM and the data
// RAM, so code, .rodata and .data share one address space starting at 0 and
// the heap/stack occupy RAM above the loaded image.
//
//   0x0000_0000  RAM   (64 KB: image + .bss + heap + stack)
//   0x1000_0000  UART  (+0 TX, +4 STATUS)
//   0x2000_0000  SYSCON (write -> halt)
// =====================================================================
`default_nettype none

module soc_libc #(
    parameter ROM_WORDS = 8192,            // 32 KB instruction ROM
    parameter RAM_WORDS = 16384,           // 64 KB data RAM (matches picolibc.ld)
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

    cpu_mc u_core (
        .clk(clk), .rst(rst), .timer_irq(1'b0), .ext_irq(1'b0), .halt(halt_q),
        .imem_addr(iaddr), .imem_rdata(irdata),
        .dmem_addr(daddr), .dmem_we(dwe), .dmem_re(),
        .dmem_wdata(dwdata), .dmem_rdata(drdata), .pc_out()
    );

    bram_rom #(.WORDS(ROM_WORDS), .INIT_FILE(IMEM_INIT)) u_rom (
        .clk(clk), .addr_word(iaddr[$clog2(ROM_WORDS)+1:2]), .rdata(irdata)
    );

    wire sel_ram  = (daddr[31:28] == 4'h0);
    wire sel_uart = (daddr[31:28] == 4'h1) && (daddr[16] == 1'b0);
    wire sel_sys  = (daddr[31:28] == 4'h2);
    wire wr_any   = |dwe;

    wire [31:0] ram_rdata, uart_rdata;
    bram_ram #(.WORDS(RAM_WORDS), .INIT_FILE(DMEM_INIT)) u_ram (
        .clk(clk), .addr_word(daddr[$clog2(RAM_WORDS)+1:2]),
        .we(sel_ram ? dwe : 4'b0000), .wdata(dwdata), .rdata(ram_rdata)
    );

    uart u_uart (
        .clk(clk), .sel(sel_uart), .we(sel_uart & wr_any),
        .addr(daddr[7:0]), .wdata(dwdata), .rdata(uart_rdata)
    );

    assign drdata = sel_uart ? uart_rdata : ram_rdata;

    reg halt_r;
    always @(posedge clk) begin
        if (rst)                   halt_r <= 1'b0;
        else if (sel_sys & wr_any) halt_r <= 1'b1;
    end
    assign halt_q = halt_r;
    assign halted = halt_r;
endmodule

`default_nettype wire
