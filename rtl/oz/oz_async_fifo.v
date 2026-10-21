// =====================================================================
// oz_async_fifo.v  -  dual-clock FIFO (Gray-coded pointers)
// ---------------------------------------------------------------------
// Carries the RISC-V console from the core clock (the 50 MHz PL
// oscillator) to the AXI clock (FCLK0 from the PS) in PS-attached builds.
// The textbook design: binary pointers count in their own domain, cross
// as Gray code through two flops (only one bit changes per step, so a
// mid-change sample is off by at most one -- never garbage), and full /
// empty are judged against the synchronised copy of the other pointer,
// which errs on the safe side (full a little early, empty a little late).
// =====================================================================
`default_nettype none

module oz_async_fifo #(
    parameter WIDTH = 8,
    parameter DEPTH = 64                  // power of two
) (
    // ---- write side ----
    input  wire             wclk,
    input  wire             wrst,
    input  wire             wvalid,
    input  wire [WIDTH-1:0] wdata,
    output wire             wready,       // not full
    // ---- read side ----
    input  wire             rclk,
    input  wire             rrst,
    output wire             rvalid,       // not empty
    output wire [WIDTH-1:0] rdata,
    input  wire             rpop
);
    localparam AW = $clog2(DEPTH);

    reg [WIDTH-1:0] mem [0:DEPTH-1];
    reg [AW:0] wbin, rbin;                // one extra bit tells full from empty
    wire [AW:0] wgray = wbin ^ (wbin >> 1);
    wire [AW:0] rgray = rbin ^ (rbin >> 1);
    (* ASYNC_REG = "TRUE" *) reg [AW:0] rgray_w1, rgray_w2;  // read ptr in wclk
    (* ASYNC_REG = "TRUE" *) reg [AW:0] wgray_r1, wgray_r2;  // write ptr in rclk

    // ---- write domain ----
    assign wready = (wgray != {~rgray_w2[AW:AW-1], rgray_w2[AW-2:0]});
    always @(posedge wclk) begin
        if (wrst) begin wbin <= 0; rgray_w1 <= 0; rgray_w2 <= 0; end
        else begin
            {rgray_w2, rgray_w1} <= {rgray_w1, rgray};
            if (wvalid && wready) begin
                mem[wbin[AW-1:0]] <= wdata;
                wbin <= wbin + 1'b1;
            end
        end
    end

    // ---- read domain ----
    assign rvalid = (rgray != wgray_r2);
    assign rdata  = mem[rbin[AW-1:0]];
    always @(posedge rclk) begin
        if (rrst) begin rbin <= 0; wgray_r1 <= 0; wgray_r2 <= 0; end
        else begin
            {wgray_r2, wgray_r1} <= {wgray_r1, wgray};
            if (rpop && rvalid) rbin <= rbin + 1'b1;
        end
    end
endmodule

`default_nettype wire
