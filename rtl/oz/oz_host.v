// =====================================================================
// oz_host.v  -  the Cortex-A9's view of the RISC-V (PS-attached builds)
// ---------------------------------------------------------------------
// An AXI4-Lite slave on M_AXI_GP0 (0x4000_0000 in the PS map, FCLK0
// domain) through which the PS loads a program, starts the core, reads
// its console, and sees how it finished. The core itself runs on the PL
// oscillator, so everything here crosses clock domains:
//
//   CTRL.run  --2FF-->            core reset (held until the PS sets it)
//   halted    <--2FF--            exit code sampled once halted is seen
//   console   <--async FIFO--     bytes the RISC-V writes to its CONSOLE
//   memories  <--toggle handshake--> one word per request, through the
//                                 BRAMs' second port in the core domain
//
// Register map (byte offsets from 0x4000_0000):
//   0x00 ID        ro  0x4F5A5256 ("OZRV")
//   0x04 CTRL      rw  [0] run: 1 = release the core from reset
//   0x08 STATUS    ro  [0] run  [1] halted  [2] console byte waiting
//   0x0C EXIT      ro  value the program wrote to SYSCON (valid when halted)
//   0x10 CONSOLE   ro  [8] valid  [7:0] byte -- a read POPS the byte
//   0x14 FEATURES  ro  what this bitstream was configured with (see rvgen)
//   0x18 IMEM_SIZE ro  bytes          0x1C DMEM_SIZE ro  bytes
//   0x20 CFG_HASH  ro  hash of the .config this bitstream was built from
//   0x24 CORE_HZ   ro  core clock frequency
//   0x10_0000 ...  IMEM window (word access)
//   0x20_0000 ...  DMEM window (word access)
// =====================================================================
`default_nettype none

module oz_host #(
    parameter [31:0] FEATURES   = 32'd0,
    parameter [31:0] IMEM_BYTES = 32'd16384,
    parameter [31:0] DMEM_BYTES = 32'd16384,
    parameter [31:0] CFG_HASH   = 32'd0,
    parameter [31:0] CORE_HZ    = 32'd50000000
) (
    // ---- AXI4-Lite slave (aclk domain) ----
    input  wire        aclk,
    input  wire        aresetn,
    input  wire [31:0] awaddr,
    input  wire        awvalid,
    output wire        awready,
    input  wire [31:0] wdata,
    input  wire [3:0]  wstrb,
    input  wire        wvalid,
    output wire        wready,
    output wire [1:0]  bresp,
    output wire        bvalid,
    input  wire        bready,
    input  wire [31:0] araddr,
    input  wire        arvalid,
    output wire        arready,
    output reg  [31:0] rdata,
    output wire [1:0]  rresp,
    output wire        rvalid,
    input  wire        rready,

    // ---- core side (cclk domain) ----
    input  wire        cclk,
    input  wire        crst,            // core-domain power-on reset
    output wire        run,             // synchronised CTRL.run
    input  wire        con_valid,
    input  wire [7:0]  con_data,
    output wire        con_ready,
    input  wire        halted,
    input  wire [31:0] exit_code,
    output reg         h_en,
    output reg         h_dmem,
    output reg         h_we,
    output reg  [15:0] h_addr,
    output reg  [31:0] h_wdata,
    input  wire [31:0] h_rdata
);
    wire arst = ~aresetn;

    // =================================================================
    // console: core -> PS
    // =================================================================
    wire       con_avail;
    wire [7:0] con_byte;
    reg        con_pop;
    oz_async_fifo #(.WIDTH(8), .DEPTH(64)) u_con (
        .wclk(cclk), .wrst(crst), .wvalid(con_valid), .wdata(con_data), .wready(con_ready),
        .rclk(aclk), .rrst(arst), .rvalid(con_avail), .rdata(con_byte), .rpop(con_pop));

    // =================================================================
    // control / status
    // =================================================================
    reg ctrl_run;
    (* ASYNC_REG = "TRUE" *) reg run_c1, run_c2;
    always @(posedge cclk)
        if (crst) begin run_c1 <= 1'b0; run_c2 <= 1'b0; end
        else      begin run_c1 <= ctrl_run; run_c2 <= run_c1; end
    assign run = run_c2;

    (* ASYNC_REG = "TRUE" *) reg halt_a1, halt_a2;
    reg [31:0] exit_a;
    always @(posedge aclk) begin
        halt_a1 <= halted & ~arst; halt_a2 <= halt_a1 & ~arst;
        if (halt_a2) exit_a <= exit_code;     // stable long before halted crosses
    end

    // =================================================================
    // memory requests: toggle handshake into the core domain
    // =================================================================
    reg        req_tgl;                       // aclk: flips to start a request
    reg        rq_we, rq_dmem;
    reg [15:0] rq_addr;
    reg [31:0] rq_wdata;
    (* ASYNC_REG = "TRUE" *) reg req_c1, req_c2;
    reg        req_c3, ack_tgl, h_cap;
    reg [31:0] resp;
    always @(posedge cclk) begin
        req_c1 <= req_tgl; req_c2 <= req_c1; req_c3 <= req_c2;
        h_en  <= 1'b0;
        h_cap <= h_en;
        if (crst) begin
            ack_tgl <= 1'b0; h_cap <= 1'b0;
            req_c1 <= 1'b0; req_c2 <= 1'b0; req_c3 <= 1'b0;
        end else begin
            if (req_c2 != req_c3) begin          // a new request has arrived
                h_en <= 1'b1; h_we <= rq_we; h_dmem <= rq_dmem;
                h_addr <= rq_addr; h_wdata <= rq_wdata;
            end
            if (h_cap) begin resp <= h_rdata; ack_tgl <= ~ack_tgl; end
        end
    end
    (* ASYNC_REG = "TRUE" *) reg ack_a1, ack_a2;
    reg ack_a3;
    always @(posedge aclk)
        if (arst) begin ack_a1 <= 1'b0; ack_a2 <= 1'b0; ack_a3 <= 1'b0; end
        else      begin ack_a1 <= ack_tgl; ack_a2 <= ack_a1; ack_a3 <= ack_a2; end
    wire mem_done = (ack_a2 != ack_a3);

    // =================================================================
    // AXI4-Lite slave
    // =================================================================
    localparam S_IDLE=3'd0, S_MEMW=3'd1, S_MEMR=3'd2, S_B=3'd3, S_R=3'd4;
    reg [2:0] state;
    wire do_wr = (state == S_IDLE) & awvalid & wvalid;
    wire do_rd = (state == S_IDLE) & ~do_wr & arvalid;
    assign awready = do_wr;
    assign wready  = do_wr;
    assign arready = do_rd;
    assign bvalid  = (state == S_B);
    assign rvalid  = (state == S_R);
    assign bresp   = 2'b00;
    assign rresp   = 2'b00;

    wire [1:0] w_win = awaddr[21:20], r_win = araddr[21:20];   // 0 regs, 1 IMEM, 2 DMEM

    always @(posedge aclk) begin
        con_pop <= 1'b0;
        if (arst) begin
            state <= S_IDLE; ctrl_run <= 1'b0; req_tgl <= 1'b0; rdata <= 32'd0;
        end else case (state)
            S_IDLE: begin
                if (do_wr) begin
                    if (w_win == 2'd1 || w_win == 2'd2) begin
                        rq_we <= 1'b1; rq_dmem <= (w_win == 2'd2);
                        rq_addr <= awaddr[17:2]; rq_wdata <= wdata;
                        req_tgl <= ~req_tgl; state <= S_MEMW;
                    end else begin
                        if (awaddr[7:0] == 8'h04 && wstrb[0]) ctrl_run <= wdata[0];
                        state <= S_B;
                    end
                end else if (do_rd) begin
                    if (r_win == 2'd1 || r_win == 2'd2) begin
                        rq_we <= 1'b0; rq_dmem <= (r_win == 2'd2);
                        rq_addr <= araddr[17:2];
                        req_tgl <= ~req_tgl; state <= S_MEMR;
                    end else begin
                        case (araddr[7:0])
                            8'h00: rdata <= 32'h4F5A_5256;
                            8'h04: rdata <= {31'd0, ctrl_run};
                            8'h08: rdata <= {29'd0, con_avail, halt_a2, ctrl_run};
                            8'h0C: rdata <= exit_a;
                            8'h10: begin rdata <= {23'd0, con_avail, con_byte}; con_pop <= con_avail; end
                            8'h14: rdata <= FEATURES;
                            8'h18: rdata <= IMEM_BYTES;
                            8'h1C: rdata <= DMEM_BYTES;
                            8'h20: rdata <= CFG_HASH;
                            8'h24: rdata <= CORE_HZ;
                            default: rdata <= 32'd0;
                        endcase
                        state <= S_R;
                    end
                end
            end
            S_MEMW: if (mem_done) state <= S_B;
            S_MEMR: if (mem_done) begin rdata <= resp; state <= S_R; end
            S_B:    if (bready) state <= S_IDLE;
            S_R:    if (rready) state <= S_IDLE;
            default: state <= S_IDLE;
        endcase
    end
endmodule

`default_nettype wire
