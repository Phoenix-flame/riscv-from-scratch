`timescale 1ns/1ps
`default_nettype none
module uart_loop_tb;
    reg clk=0, rst=1; always #5 clk=~clk;
    // tx config
    reg [15:0] t_clks=16; reg [3:0] t_db=8; reg [1:0] t_par=0; reg t_s2=0;
    // rx config
    reg [15:0] r_clks=16; reg [3:0] r_db=8; reg [1:0] r_par=0; reg r_s2=0;
    reg [7:0] t_data; reg t_send; wire line, t_busy;
    wire [7:0] r_data; wire r_valid, r_ferr, r_perr;

    uart_tx_cfg utx(.clk(clk),.rst(rst),.send(t_send),.data(t_data),
        .clks_per_bit(t_clks),.data_bits(t_db),.parity_mode(t_par),.stop2(t_s2),
        .tx(line),.busy(t_busy));
    uart_rx urx(.clk(clk),.rst(rst),.rx(line),
        .clks_per_bit(r_clks),.data_bits(r_db),.parity_mode(r_par),.stop2(r_s2),
        .idle_bits(5'd0),.data(r_data),.valid(r_valid),.frame_err(r_ferr),.parity_err(r_perr),.idle());

    reg [7:0] got; reg gp, gf, vflag;
    always @(posedge clk) begin
        if (r_valid) begin got<=r_data; gp<=r_perr; gf<=r_ferr; vflag<=1'b1; end
    end
    integer fails=0;
    task xfer(input [7:0] b, input [7:0] mask, input exp_p);
        integer n; begin
            vflag=0;
            while (t_busy) @(posedge clk);            // wait for the TX to be idle
            @(negedge clk); t_data=b; t_send=1; @(negedge clk); t_send=0;
            n=0; while(!vflag && n<6000) begin @(posedge clk); n=n+1; end
            if (!vflag)                       begin $display("  FAIL: no byte (timeout)"); fails=fails+1; end
            else if ((got&mask)!==(b&mask))   begin $display("  FAIL: sent %02h got %02h", b&mask, got&mask); fails=fails+1; end
            else if (gp!==exp_p)              begin $display("  FAIL: parity_err exp %b got %b", exp_p, gp); fails=fails+1; end
            else $display("  ok %02h -> %02h  (parity_err=%b frame_err=%b)", b&mask, got&mask, gp, gf);
        end
    endtask
    task cfg(input [3:0] db, input [1:0] par, input s2);
        begin t_db=db; r_db=db; t_par=par; r_par=par; t_s2=s2; r_s2=s2; end
    endtask

    initial begin
        repeat(3) @(posedge clk); #1; rst=0; repeat(2) @(posedge clk);
        $display("8N1:"); cfg(8,0,0); xfer(8'h55,8'hFF,0); xfer(8'hA3,8'hFF,0); xfer(8'h00,8'hFF,0); xfer(8'hFF,8'hFF,0);
        $display("7E1:"); cfg(7,2,0); xfer(8'h55,8'h7F,0); xfer(8'h2A,8'h7F,0);
        $display("8O2:"); cfg(8,1,1); xfer(8'hA3,8'hFF,0); xfer(8'h10,8'hFF,0);
        $display("5N1:"); cfg(5,0,0); xfer(8'h15,8'h1F,0); xfer(8'h0A,8'h1F,0);
        $display("baud change (clks=24) 8N1:"); t_clks=24; r_clks=24; cfg(8,0,0); xfer(8'h5A,8'hFF,0);
        $display("parity MISMATCH (tx even, rx odd) -> expect parity_err:");
        t_clks=16; r_clks=16; t_db=8; r_db=8; t_s2=0; r_s2=0; t_par=2; r_par=1;
        xfer(8'h55,8'hFF,1);
        if (fails==0) $display("UART LOOPBACK: ALL PASS"); else $display("UART LOOPBACK: %0d FAIL", fails);
        $finish;
    end
endmodule
`default_nettype wire
