// =====================================================================
// soc_dbg.v  -  SoC with an on-chip debug module (gdb-style debugging)
// ---------------------------------------------------------------------
// cpu_core_dbg + RAM + UART + timer + syscon + debug_module. The DMI is
// brought to the top so a host debugger (a JTAG/UART bridge on hardware,
// or a testbench in sim) can halt the core, inspect/modify registers and
// memory, set breakpoints, and single-step. While the core is halted the
// debug module borrows the data bus to read/write memory.
// =====================================================================
`default_nettype none

module soc_dbg #(
    parameter INIT_FILE  = "",
    parameter DATA_INIT  = "",
    parameter IMEM_WORDS = 1024,
    parameter RAM_BYTES  = 4096,
    parameter NBP        = 4
) (
    input  wire        clk,
    input  wire        rst,
    output wire [31:0] pc_out,
    // DMI debug port
    input  wire        dmi_sel,
    input  wire        dmi_we,
    input  wire [7:0]  dmi_addr,
    input  wire [31:0] dmi_wdata,
    output wire [31:0] dmi_rdata
);
    // ---- core <-> bus ----
    wire [31:0] c_daddr, c_dwdata, drdata;
    wire        c_dwe; wire [2:0] c_dfunct3;
    wire        timer_irq;

    // ---- debug wires ----
    wire        dbg_halt_req, dbg_resume, dbg_step, dbg_halted, dbg_pc_we, dbg_reg_we;
    wire [31:0] dbg_pc, dbg_pc_wdata, dbg_reg_rdata, dbg_reg_wdata;
    wire [4:0]  dbg_reg_addr;
    wire [NBP-1:0]    bp_en;
    wire [NBP*32-1:0] bp_addr_flat;
    wire        dm_mem_req, dm_mem_we;
    wire [31:0] dm_mem_addr, dm_mem_wdata;

    cpu_core_dbg #(.INIT_FILE(INIT_FILE), .IMEM_WORDS(IMEM_WORDS), .NBP(NBP)) u_core (
        .clk(clk), .rst(rst), .timer_irq(timer_irq),
        .pc_out(pc_out), .instr_out(),
        .dmem_addr(c_daddr), .dmem_wdata(c_dwdata), .dmem_we(c_dwe),
        .dmem_funct3(c_dfunct3), .dmem_rdata(drdata),
        .dbg_halt_req(dbg_halt_req), .dbg_resume(dbg_resume), .dbg_step(dbg_step),
        .dbg_halted(dbg_halted), .dbg_pc(dbg_pc),
        .dbg_pc_we(dbg_pc_we), .dbg_pc_wdata(dbg_pc_wdata),
        .dbg_reg_addr(dbg_reg_addr), .dbg_reg_rdata(dbg_reg_rdata),
        .dbg_reg_we(dbg_reg_we), .dbg_reg_wdata(dbg_reg_wdata),
        .bp_en(bp_en), .bp_addr_flat(bp_addr_flat)
    );

    debug_module #(.NBP(NBP)) u_dm (
        .clk(clk), .rst(rst),
        .dmi_sel(dmi_sel), .dmi_we(dmi_we), .dmi_addr(dmi_addr),
        .dmi_wdata(dmi_wdata), .dmi_rdata(dmi_rdata),
        .dbg_halt_req(dbg_halt_req), .dbg_resume(dbg_resume), .dbg_step(dbg_step),
        .dbg_halted(dbg_halted), .dbg_pc(dbg_pc),
        .dbg_pc_we(dbg_pc_we), .dbg_pc_wdata(dbg_pc_wdata),
        .dbg_reg_addr(dbg_reg_addr), .dbg_reg_rdata(dbg_reg_rdata),
        .dbg_reg_we(dbg_reg_we), .dbg_reg_wdata(dbg_reg_wdata),
        .bp_en(bp_en), .bp_addr_flat(bp_addr_flat),
        .dm_mem_req(dm_mem_req), .dm_mem_we(dm_mem_we),
        .dm_mem_addr(dm_mem_addr), .dm_mem_wdata(dm_mem_wdata), .dm_mem_rdata(drdata)
    );

    // ---- bus muxing: the DM borrows the data bus while it issues a request ----
    wire [31:0] b_addr   = dm_mem_req ? dm_mem_addr   : c_daddr;
    wire [31:0] b_wdata  = dm_mem_req ? dm_mem_wdata  : c_dwdata;
    wire        b_we     = dm_mem_req ? dm_mem_we     : c_dwe;
    wire [2:0]  b_funct3 = dm_mem_req ? 3'b010        : c_dfunct3;

    wire sel_ram   = (b_addr[31:28] == 4'h0);
    wire sel_uart  = (b_addr[31:28] == 4'h1) && (b_addr[16] == 1'b0);
    wire sel_timer = (b_addr[31:28] == 4'h1) && (b_addr[16] == 1'b1);
    wire sel_sys   = (b_addr[31:28] == 4'h2);

    wire [31:0] ram_rdata;
    dmem #(.BYTES(RAM_BYTES), .INIT_FILE(DATA_INIT)) u_ram (
        .clk(clk), .we(b_we && sel_ram),
        .addr(b_addr), .wdata(b_wdata), .funct3(b_funct3), .rdata(ram_rdata)
    );
    wire [31:0] uart_rdata;
    uart u_uart (.clk(clk), .sel(sel_uart), .we(b_we && sel_uart),
                 .addr(b_addr[7:0]), .wdata(b_wdata), .rdata(uart_rdata));
    wire [31:0] timer_rdata;
    timer u_timer (.clk(clk), .rst(rst), .sel(sel_timer), .we(b_we && sel_timer),
                   .addr(b_addr[7:0]), .wdata(b_wdata), .rdata(timer_rdata), .irq(timer_irq));
    syscon u_syscon (.clk(clk), .sel(sel_sys), .we(b_we && sel_sys), .wdata(b_wdata));

    assign drdata = sel_uart ? uart_rdata : sel_timer ? timer_rdata : ram_rdata;
endmodule

`default_nettype wire
