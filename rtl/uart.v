// =====================================================================
// uart.v  -  Minimal memory-mapped UART transmitter (simulation model)
// ---------------------------------------------------------------------
// Register map (offsets from the device base address):
//   +0x0  TX     : write a byte -> transmit it (printed to the console)
//   +0x4  STATUS : read -> bit0 = TX ready (always 1 here)
//
// A real UART would serialize the byte out a pin at a baud rate; in
// simulation "transmit" means printing the character with $write, which
// is the standard way to get console output from an HDL model.
// =====================================================================
`default_nettype none

module uart (
    input  wire        clk,
    input  wire        sel,        // this device is addressed
    input  wire        we,         // store
    input  wire [7:0]  addr,       // offset within the device
    input  wire [31:0] wdata,
    output reg  [31:0] rdata
);
    // Write to TX (offset 0): print the low byte.
    always @(posedge clk) begin
        if (sel && we && (addr[3:0] == 4'h0))
            $write("%c", wdata[7:0]);
    end

    // Reads.
    always @(*) begin
        case (addr[3:0])
            4'h4   : rdata = 32'h0000_0001;  // STATUS: TX always ready
            default: rdata = 32'h0000_0000;
        endcase
    end
endmodule

`default_nettype wire
