// =====================================================================
// uart16550.v  -  an ns16550a-compatible UART (the PC serial port)
// ---------------------------------------------------------------------
// Every RISC-V boot loader, OpenSBI, U-Boot and Linux's 8250 driver can
// talk to a 16550 knowing nothing but its address, its input clock and
// its register spacing -- three properties a device-tree node carries.
// So the boot platform (Step 49) uses this instead of the project's own
// UART: the framers are still ours (uart_tx_cfg / uart_rx, Step 30), the
// register interface in front of them is the 1987 one.
//
// Registers are 8 bits wide at a 4-byte stride (DT: reg-shift = <2>,
// reg-io-width = <4>); DLAB is LCR bit 7:
//
//   +0x00  RBR (R) receive buffer          THR (W) transmit holding
//          DLL (DLAB=1) divisor latch, low byte
//   +0x04  IER   b0 rx data  b1 THR empty  b2 line status  b3 modem
//          DLM (DLAB=1) divisor latch, high byte
//   +0x08  IIR (R) b0 = 0: interrupt pending; b3:1 which (6 line status,
//                  4 rx data, C rx timeout, 2 THR empty); b7:6 = 11 FIFOs on
//          FCR (W) b0 FIFO enable  b1 clear RX  b2 clear TX  b7:6 RX trigger
//   +0x0C  LCR   b1:0 5..8 data bits  b2 2 stop  b3 parity  b4 even  b6 break  b7 DLAB
//   +0x10  MCR   b0 DTR b1 RTS b2 OUT1 b3 OUT2  b4 loopback
//   +0x14  LSR   b0 data ready  b1 overrun  b2 parity  b3 framing  b5 THR empty
//                b6 transmitter empty  b7 error in RX FIFO
//   +0x18  MSR   (no modem lines: CTS, DSR, DCD read as asserted)
//   +0x1C  SCR   scratch
//
// Baud rate = clk / (16 * divisor): the framers count 16*divisor clocks
// per bit. Both FIFOs are 16 deep; with FCR.0 = 0 (16450 mode) each acts
// as a single holding register.
//
// Read side effects -- RBR pops, LSR clears the error bits, IIR clears a
// THR-empty interrupt -- fire on `sel & ~we`, which the SoC drives only
// for a real load (a D-port request), never on a bare address match.
//
// Simplifications: the error bits are latched when a bad character
// ARRIVES (a real 16550 shows them when it reaches the FIFO head); no
// break detection (BI reads 0); stick parity ignored; no modem-status
// interrupt.
// =====================================================================
`default_nettype none

module uart16550 #(
    parameter [15:0] DEF_DIV = 16'd1        // divisor latch at reset
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        sel,                 // a load or store to this device
    input  wire        we,
    input  wire [4:0]  addr,                // byte offset [4:2] = register
    input  wire [31:0] wdata,
    output reg  [31:0] rdata,
    input  wire        rx,
    output wire        tx,
    output wire        irq
);
    localparam DEPTH = 16;

    reg [7:0]  ier, lcr, mcr, scr;
    reg [15:0] div;
    reg        fifo_en;
    reg [1:0]  rx_trig;
    reg        oe, pe, fe;                  // latched line-status errors
    reg        thre_ip;                     // THR-empty interrupt pending

    wire [2:0] ra   = addr[4:2];
    wire       dlab = lcr[7];
    wire       wr   = sel & we;
    wire       rd   = sel & ~we;

    // ---- framing, from LCR and the divisor ----
    wire [15:0] cpb    = {(div == 16'd0) ? 12'd1 : div[11:0], 4'b0000};
    wire [3:0]  dbits  = 4'd5 + {2'b00, lcr[1:0]};
    wire [1:0]  parity = ~lcr[3] ? 2'd0 : lcr[4] ? 2'd2 : 2'd1;   // none / even / odd
    wire        loop   = mcr[4];

    // ---- TX FIFO -> transmitter ----
    reg  [7:0] txq [0:DEPTH-1];
    reg  [3:0] tx_rd, tx_wr;
    reg  [4:0] tx_n;
    wire       tx_busy, tx_line;
    wire       tx_send = (tx_n != 5'd0) & ~tx_busy;
    uart_tx_cfg u_tx (
        .clk(clk), .rst(rst), .send(tx_send), .data(txq[tx_rd]),
        .clks_per_bit(cpb), .data_bits(dbits), .parity_mode(parity), .stop2(lcr[2]),
        .tx(tx_line), .busy(tx_busy));
    assign tx = loop ? 1'b1 : (tx_line & ~lcr[6]);              // LCR.6 = send break

    // ---- receiver -> RX FIFO ----
    wire [7:0] rx_byte; wire rx_v, rx_fe, rx_pe;
    uart_rx u_rx (
        .clk(clk), .rst(rst), .rx(loop ? tx_line : rx),
        .clks_per_bit(cpb), .data_bits(dbits), .parity_mode(parity), .stop2(lcr[2]),
        .idle_bits(5'd0), .data(rx_byte), .valid(rx_v), .frame_err(rx_fe),
        .parity_err(rx_pe), .idle());
    reg  [7:0] rxq [0:DEPTH-1];
    reg  [3:0] rx_rd, rx_wr;
    reg  [4:0] rx_n;
    wire [4:0] rx_cap = fifo_en ? DEPTH[4:0] : 5'd1;
    wire [4:0] tx_cap = fifo_en ? DEPTH[4:0] : 5'd1;
    wire       pop_rx = rd & (ra == 3'd0) & ~dlab & (rx_n != 5'd0);
    wire       push_rx = rx_v & (rx_n != rx_cap);
    wire       push_tx = wr & (ra == 3'd0) & ~dlab & (tx_n != tx_cap);

    // ---- receive timeout: data waiting, nothing in or out for ~4 chars ----
    reg  [21:0] idle_clk;
    wire [21:0] tmo = {cpb, 5'd0} + {2'b0, cpb, 3'd0};          // 40 bit times
    wire        cti = (rx_n != 5'd0) & (idle_clk >= tmo);

    // ---- interrupt identification, highest priority first ----
    wire        rx_level = fifo_en ? (rx_n >= (rx_trig == 2'd0 ? 5'd1  : rx_trig == 2'd1 ? 5'd4 :
                                               rx_trig == 2'd2 ? 5'd8  : 5'd14))
                                   : (rx_n != 5'd0);
    wire        int_rls  = ier[2] & (oe | pe | fe);
    wire        int_rda  = ier[0] & rx_level;
    wire        int_cti  = ier[0] & fifo_en & cti;
    wire        int_thre = ier[1] & thre_ip;
    wire [3:0]  iid      = int_rls  ? 4'h6 : int_rda ? 4'h4 : int_cti ? 4'hC :
                           int_thre ? 4'h2 : 4'h1;
    assign irq = ~iid[0];

    integer k;
    initial for (k = 0; k < DEPTH; k = k + 1) begin rxq[k] = 8'd0; txq[k] = 8'd0; end

    always @(posedge clk) begin
        if (rst) begin
            ier <= 8'd0; lcr <= 8'd0; mcr <= 8'd0; scr <= 8'd0; div <= DEF_DIV;
            fifo_en <= 1'b0; rx_trig <= 2'd0; oe <= 1'b0; pe <= 1'b0; fe <= 1'b0;
            thre_ip <= 1'b0; tx_rd <= 4'd0; tx_wr <= 4'd0; tx_n <= 5'd0;
            rx_rd <= 4'd0; rx_wr <= 4'd0; rx_n <= 5'd0; idle_clk <= 22'd0;
        end else begin
            // TX FIFO
            if (push_tx) begin txq[tx_wr] <= wdata[7:0]; tx_wr <= tx_wr + 4'd1; end
            if (tx_send) tx_rd <= tx_rd + 4'd1;
            tx_n <= tx_n + {4'd0, push_tx} - {4'd0, tx_send};
            if (push_tx) thre_ip <= 1'b0;
            else if (tx_send && tx_n == 5'd1) thre_ip <= 1'b1;      // just went empty

            // RX FIFO
            if (push_rx) begin rxq[rx_wr] <= rx_byte; rx_wr <= rx_wr + 4'd1; end
            if (pop_rx)  rx_rd <= rx_rd + 4'd1;
            rx_n <= rx_n + {4'd0, push_rx} - {4'd0, pop_rx};
            idle_clk <= (push_rx | pop_rx | (rx_n == 5'd0)) ? 22'd0 :
                        (idle_clk >= tmo) ? idle_clk : idle_clk + 22'd1;

            // line status: set on arrival, cleared by reading LSR
            if (rd && ra == 3'd5) begin oe <= 1'b0; pe <= 1'b0; fe <= 1'b0; end
            if (rx_v) begin
                if (rx_n == rx_cap) oe <= 1'b1;
                if (rx_pe) pe <= 1'b1;
                if (rx_fe) fe <= 1'b1;
            end
            // reading IIR while it reports THR-empty acknowledges it
            if (rd && ra == 3'd2 && iid == 4'h2) thre_ip <= 1'b0;

            if (wr) case (ra)
                3'd0: if (dlab) div[7:0] <= wdata[7:0];
                3'd1: if (dlab) div[15:8] <= wdata[7:0];
                      else begin
                          ier <= {4'd0, wdata[3:0]};
                          // enabling the interrupt while the FIFO is empty raises it
                          if (wdata[1] & ~ier[1] & (tx_n == 5'd0) & ~push_tx) thre_ip <= 1'b1;
                      end
                3'd2: begin
                          fifo_en <= wdata[0]; rx_trig <= wdata[7:6];
                          if (wdata[1] || (wdata[0] != fifo_en)) begin   // clear RX
                              rx_rd <= 4'd0; rx_wr <= 4'd0; rx_n <= 5'd0;
                          end
                          if (wdata[2] || (wdata[0] != fifo_en)) begin   // clear TX
                              tx_rd <= 4'd0; tx_wr <= 4'd0; tx_n <= 5'd0;
                          end
                      end
                3'd3: lcr <= wdata[7:0];
                3'd4: mcr <= {3'd0, wdata[4:0]};
                3'd7: scr <= wdata[7:0];
                default: ;
            endcase
        end
    end

    wire [7:0] rx_head = rxq[rx_rd];
    wire [7:0] lsr = {fifo_en & (pe | fe), (tx_n == 5'd0) & ~tx_busy, (tx_n == 5'd0),
                      1'b0, fe, pe, oe, (rx_n != 5'd0)};
    wire [7:0] msr = loop ? {mcr[3], mcr[2], mcr[0], mcr[1], 4'd0} : 8'hB0;
    always @(*) begin
        case (ra)
            3'd0: rdata = {24'd0, dlab ? div[7:0]  : rx_head};
            3'd1: rdata = {24'd0, dlab ? div[15:8] : ier};
            3'd2: rdata = {24'd0, {2{fifo_en}}, 2'b00, iid};
            3'd3: rdata = {24'd0, lcr};
            3'd4: rdata = {24'd0, mcr};
            3'd5: rdata = {24'd0, lsr};
            3'd6: rdata = {24'd0, msr};
            default: rdata = {24'd0, scr};
        endcase
    end
endmodule

`default_nettype wire
