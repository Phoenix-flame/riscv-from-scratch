// =====================================================================
// soc_boot.v  -  a boot platform: ROM + RAM + standard devices
// ---------------------------------------------------------------------
// Step 49. Every SoC so far put the program into the instruction ROM at
// time zero. This one boots like a real machine: the only thing in it at
// power-on is a boot ROM, which loads programs over the serial port into
// RAM and runs them. Three things make that possible:
//
//   * ONE memory behind both ports. The I-port fetches from the same RAM
//     the D-port writes, so a stored byte can become an instruction (the
//     core's FENCE.I refetches whatever is behind it).
//   * the standard devices, at the addresses of QEMU's `virt` board, so
//     the device tree describing them uses compatible strings that
//     OpenSBI, U-Boot and Linux already have drivers for:
//
//       0x0000_1000  boot ROM      ROM_WORDS*4 bytes (reset vector)
//       0x0010_0000  test device   "sifive,test0": 0x5555 = power off,
//                                   0x3333 | code << 16 = fail with code,
//                                   0x7777 = reset (back into the ROM)
//       0x0200_0000  CLINT         "sifive,clint0"  (msip / mtimecmp / mtime)
//       0x1000_0000  UART          "ns16550a", reg-shift 2
//       0x8000_0000  RAM           RAM_WORDS*4 bytes, mirrored through
//                                   the 256 MiB window (unused address
//                                   bits are not decoded)
//
//   * mtime wired into the core as the `time` CSR.
//
// A reset through the test device (SBI system_reset -> 0x7777) resets the
// core and the devices but not the memories, like a warm reset: the ROM
// starts over and can load the next program.
//
// Memories are ideal (combinational, always ready) as in soc_pipe_u. An
// access to an unmapped address reads 0 and a write is dropped -- there
// is no bus error -- and a fetch from one reads 0, an illegal
// instruction.
// =====================================================================
`default_nettype none

module soc_boot #(
    parameter ROM_WORDS    = 4096,        // 16 KiB boot ROM
    parameter RAM_WORDS    = 65536,       // 256 KiB RAM
    parameter BOOTROM_INIT = "",
    parameter [15:0] UART_DIV = 16'd1,    // divisor latch at reset
    parameter TLB_ENTRIES  = 4,
    parameter BPRED        = 1,
    parameter V_EXT        = 0            // no vectors: this platform is for scalar OSes
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        uart_rx_pin,
    output wire        uart_tx_pin,
    output wire        halted,            // the test device was written
    output wire [15:0] exit_code,         // 0 = powered off cleanly
    output wire        warm_reset         // a reset through the test device is under way
);
    localparam [31:0] ROM_BASE = 32'h0000_1000, ROM_BYTES = ROM_WORDS * 4;

    wire [31:0] iaddr, daddr, dwdata;
    reg  [31:0] irdata, drdata;
    wire        ireq, dreq;
    wire [3:0]  dwe;
    wire        timer_irq, retire;
    wire [63:0] mtime;
    wire        sys_rst;                  // power-on reset, or a warm reset

    cpu_pipe_u #(.RESET_PC(ROM_BASE), .TLB_ENTRIES(TLB_ENTRIES), .BPRED(BPRED),
                 .V_EXT(V_EXT)) u_core (
        .clk(clk), .rst(sys_rst), .timer_irq(timer_irq), .mtime(mtime), .halt(halted),
        .i_addr(iaddr), .i_req(ireq), .i_rdata(irdata), .i_ready(1'b1),
        .d_addr(daddr), .d_req(dreq), .d_we(dwe), .d_wdata(dwdata),
        .d_rdata(drdata), .d_ready(1'b1),
        .pc_out(), .retire(retire)
    );

    // ---- the two memories, each readable from both ports ----
    reg [31:0] rom [0:ROM_WORDS-1];
    reg [31:0] ram [0:RAM_WORDS-1];
    integer k;
    initial begin
        for (k = 0; k < ROM_WORDS; k = k + 1) rom[k] = 32'd0;
        for (k = 0; k < RAM_WORDS; k = k + 1) ram[k] = 32'd0;
        if (BOOTROM_INIT != "") $readmemh(BOOTROM_INIT, rom);
    end
    function in_rom; input [31:0] a; in_rom = (a >= ROM_BASE) && (a - ROM_BASE < ROM_BYTES); endfunction
    function in_ram; input [31:0] a; in_ram = (a[31:28] == 4'h8); endfunction
    function [$clog2(ROM_WORDS)-1:0] rom_idx; input [31:0] a; rom_idx = (a - ROM_BASE) >> 2; endfunction
    function [$clog2(RAM_WORDS)-1:0] ram_idx; input [31:0] a; ram_idx = a[$clog2(RAM_WORDS)+1:2]; endfunction

    // (array reads as continuous assigns: inside always @(*) Icarus would
    //  re-run the block on every write to either array -- 5x slower)
    wire [31:0] irom = rom[rom_idx(iaddr)], iram = ram[ram_idx(iaddr)];
    always @(*)
        irdata = in_rom(iaddr) ? irom :
                 in_ram(iaddr) ? iram : 32'd0;

    // ---- D-side decode ----
    wire sel_rom   = in_rom(daddr);
    wire sel_ram   = in_ram(daddr);
    wire sel_test  = (daddr[31:12] == 20'h00100);
    wire sel_clint = (daddr[31:16] == 16'h0200);
    wire sel_uart  = (daddr[31:12] == 20'h10000);
    wire wr_any    = dreq & (|dwe);

    wire [$clog2(RAM_WORDS)-1:0] rw = ram_idx(daddr);
    always @(posedge clk)
        if (dreq && sel_ram) begin
            if (dwe[0]) ram[rw][7:0]   <= dwdata[7:0];
            if (dwe[1]) ram[rw][15:8]  <= dwdata[15:8];
            if (dwe[2]) ram[rw][23:16] <= dwdata[23:16];
            if (dwe[3]) ram[rw][31:24] <= dwdata[31:24];
        end

    wire [31:0] clint_rdata, uart_rdata;
    clint_sifive u_clint (
        .clk(clk), .rst(sys_rst), .sel(dreq & sel_clint), .we(wr_any),
        .addr(daddr[15:0]), .wdata(dwdata), .rdata(clint_rdata),
        .timer_irq(timer_irq), .soft_irq(), .mtime_o(mtime));
    uart16550 #(.DEF_DIV(UART_DIV)) u_uart (
        .clk(clk), .rst(sys_rst), .sel(dreq & sel_uart), .we(wr_any),
        .addr(daddr[4:0]), .wdata(dwdata), .rdata(uart_rdata),
        .rx(uart_rx_pin), .tx(uart_tx_pin), .irq());

    // ---- the test device: power off (pass), fail with a code, or reset ----
    reg        halt_r;
    reg [15:0] code_r;
    reg [2:0]  wrst;                      // warm reset: held for a few cycles
    always @(posedge clk)
        if (rst) begin halt_r <= 1'b0; code_r <= 16'd0; wrst <= 3'd0; end
        else begin
            if (wrst != 3'd0) wrst <= wrst - 3'd1;
            if (sel_test & wr_any & ~halt_r & (wrst == 3'd0)) begin
                if (dwdata[15:0] == 16'h5555)      begin halt_r <= 1'b1; code_r <= 16'd0; end
                else if (dwdata[15:0] == 16'h3333) begin halt_r <= 1'b1;
                    code_r <= (dwdata[31:16] == 16'd0) ? 16'd1 : dwdata[31:16]; end
                else if (dwdata[15:0] == 16'h7777) wrst <= 3'd4;
            end
        end
    assign sys_rst    = rst | (wrst != 3'd0);
    assign warm_reset = (wrst != 3'd0);
    assign halted     = halt_r;
    assign exit_code  = code_r;

    wire [31:0] dram = ram[rw], drom = rom[rom_idx(daddr)];
    always @(*)
        drdata = sel_ram   ? dram :
                 sel_rom   ? drom :
                 sel_uart  ? uart_rdata :
                 sel_clint ? clint_rdata : 32'd0;
endmodule

`default_nettype wire
